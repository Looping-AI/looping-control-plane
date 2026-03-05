import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import Time "mo:core/Time";
import Text "mo:core/Text";
import Types "../../types";
import ConversationModel "../../models/conversation-model";
import AgentModel "../../models/agent-model";
import GroqWrapper "../../wrappers/groq-wrapper";
import InstructionComposer "../../instructions/instruction-composer";
import InstructionTypes "../../instructions/instruction-types";
import FunctionToolRegistry "../../tools/function-tool-registry";
import McpToolRegistry "../../tools/mcp-tool-registry";
import ToolExecutor "../../tools/tool-executor";
import ToolTypes "../../tools/tool-types";
import AgentHelpers "../helpers";
import WorkspaceModel "../../models/workspace-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Maximum number of previous conversation messages to include as context
  let MAX_CONVERSATION_HISTORY : Nat = 30;

  /// All org-admin data the org-admin agent needs at execution time.
  /// Carries the full workspace state so the agent can list, create,
  /// and configure workspaces and their channel anchors.
  public type AdminCtx = {
    workspaces : WorkspaceModel.WorkspacesState;
    // Slack bot token — used to verify channel existence before anchoring
    slackBotToken : ?Text;
    // Resolved Slack user identity — used for authorization checks in write tools
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;
  };

  /// ProcessResult mirrors the WorkPlanningAgent return type so the orchestrator
  /// can use a shared result type across all agents.
  public type ProcessResult = {
    #ok : {
      response : Text;
      steps : [Types.ProcessingStep];
    };
    #err : {
      message : Text;
      steps : [Types.ProcessingStep];
    };
  };

  /// Process a message using the org-admin agent configuration.
  ///
  /// `agent` drives persona, tool filtering, and knowledge sources.
  /// `ctx` carries the org-admin data (workspace state for channel-anchor management).
  /// `conversationEntry` carries the timeline entry for LLM context.
  /// Pass `null` when no persistent history exists.
  /// Tool call / tool response messages are ephemeral and never written to the store.
  public func process(
    agent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    conversationEntry : ?ConversationModel.TimelineEntry,
    ctx : AdminCtx,
    message : Text,
    apiKey : Text,
  ) : async ProcessResult {
    var steps : List.List<Types.ProcessingStep> = List.empty();

    // Derive model text from the agent's llmModel — not a caller-supplied param
    let modelText = AgentModel.llmModelToText(agent.llmModel);

    // Build instructions driven by agent configuration
    let instructions = buildInstructions(agent);

    // Build tool resources — only workspace-management tools for this agent
    let toolResources : ToolTypes.ToolResources = {
      workspaceId = null; // org-admin tools operate on entire WorkspacesState, not a single workspace
      groqApiKey = ?apiKey;
      slackBotToken = ctx.slackBotToken;
      userAuthContext = ctx.userAuthContext;
      valueStreams = null;
      metrics = null;
      objectives = null;
      workspaces = ?{
        state = ctx.workspaces;
        write = true;
      };
    };

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions(toolResources);
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);

    // Apply blocklist filtering via the public helper
    let filteredTools = AgentHelpers.applyToolBlocklist(agent, allTools);

    let toolsOpt : ?[GroqWrapper.Tool] = if (filteredTools.size() == 0) null else ?filteredTools;

    // Build LLM context from persistent conversation history.
    // Tool call / tool response artifacts are appended to inputMessages during the
    // reasoning loop below but are NOT written to the conversation store — they are
    // ephemeral and discarded when this function returns.
    let inputMessages = buildContextMessages(conversationEntry);

    // Add the new user message
    List.add(inputMessages, { role = #user; content = message });

    var iteration = 0;

    loop {
      // groqApiKey is used as the model key; org-admin context is workspace-0 scoped
      let groqResult = await GroqWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        modelText,
        #workspace(0),
        ?instructions,
        null,
        toolsOpt,
      );

      switch (groqResult) {
        case (#ok(#textResponse(response))) {
          List.add(
            steps,
            {
              action = "llm_text_response";
              result = #ok;
              timestamp = Time.now();
            },
          );
          return #ok({ response; steps = List.toArray(steps) });
        };

        case (#ok(#toolCalls(calls))) {
          // Format tool call message (ephemeral — not written to conversation store)
          let toolCallContent = "Using tools: " # Array.foldLeft<GroqWrapper.ToolCall, Text>(
            calls,
            "",
            func(acc, call) {
              if (acc == "") call.toolName else acc # ", " # call.toolName;
            },
          );

          // Append tool call to in-memory input for the next LLM round
          List.add(inputMessages, { role = #assistant; content = toolCallContent });

          // Execute tool calls
          let toolResults = await ToolExecutor.execute(toolResources, mcpToolRegistry, calls);

          // Add individual execution steps for each tool
          for (i in Array.keys(toolResults)) {
            let toolName = calls[i].toolName;
            let stepResult : { #ok; #err : Text } = switch (toolResults[i].result) {
              case (#success(_)) { #ok };
              case (#error(msg)) { #err(msg) };
            };
            List.add(
              steps,
              {
                action = "tool_execution_" # toolName;
                result = stepResult;
                timestamp = Time.now();
              },
            );
          };

          // Append tool results to in-memory input for the next LLM round
          let formattedResults = ToolExecutor.formatResultsForLlm(toolResults);
          List.add(inputMessages, { role = #assistant; content = formattedResults });

          iteration += 1;
          if (iteration >= MAX_ITERATIONS) {
            let errMsg = "Max tool iterations reached (" # Nat.toText(MAX_ITERATIONS) # ")";
            List.add(
              steps,
              {
                action = "max_iterations_exceeded";
                result = #err(errMsg);
                timestamp = Time.now();
              },
            );
            return #err({ message = errMsg; steps = List.toArray(steps) });
          };
          // Continue loop
        };

        case (#err(error)) {
          let errMsg = "Groq API Error: " # error;
          List.add(
            steps,
            {
              action = "llm_api_error";
              result = #err(errMsg);
              timestamp = Time.now();
            },
          );
          return #err({ message = errMsg; steps = List.toArray(steps) });
        };
      };
    };
  };

  /// Build LLM input messages from a TimelineEntry (conversation history).
  ///
  /// Role mapping:
  ///   ConversationMessage.userAuthContext = null  → #assistant  (bot/agent message)
  ///   ConversationMessage.userAuthContext = ?_    → #user       (human message)
  private func buildContextMessages(
    conversationEntry : ?ConversationModel.TimelineEntry
  ) : List.List<GroqWrapper.ResponseInputMessage> {
    let inputMessages = List.empty<GroqWrapper.ResponseInputMessage>();
    switch (conversationEntry) {
      case (null) { /* no history — start fresh */ };
      case (?#post msg) {
        let role : GroqWrapper.MessageRole = switch (msg.userAuthContext) {
          case (null) { #assistant };
          case (?_) { #user };
        };
        List.add(inputMessages, { role; content = msg.text });
      };
      case (?#thread thread) {
        let messagesArr = Map.toArray(thread.messages);
        let startIndex = if (messagesArr.size() > MAX_CONVERSATION_HISTORY) {
          Nat.sub(messagesArr.size(), MAX_CONVERSATION_HISTORY);
        } else {
          0;
        };
        var i = startIndex;
        while (i < messagesArr.size()) {
          let (_, msg) = messagesArr[i];
          let role : GroqWrapper.MessageRole = switch (msg.userAuthContext) {
            case (null) { #assistant };
            case (?_) { #user };
          };
          List.add(inputMessages, { role; content = msg.text });
          i += 1;
        };
      };
    };
    inputMessages;
  };

  /// Build instructions for the org-admin persona.
  ///
  /// No value-stream / metrics / objectives context is included — this agent is
  /// focused on org and workspace channel-anchor management.
  /// If `agent.sources` is non-empty, an `"agent-sources"` block is appended.
  private func buildInstructions(agent : AgentModel.AgentRecord) : Text {
    let customBlocks : [InstructionTypes.InstructionBlock] = if (agent.sources.size() > 0) {
      AgentHelpers.sourceBlocks(agent);
    } else {
      [];
    };

    InstructionComposer.compose(
      AgentHelpers.categoryToRole(agent.category, agent.name),
      [], // no context-layer IDs — org admin has no planning pipeline state
      customBlocks,
    );
  };

};
