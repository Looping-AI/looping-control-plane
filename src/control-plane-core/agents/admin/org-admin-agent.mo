import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Time "mo:core/Time";
import TextUtils "../../utilities/text-utils";
import Types "../../types";
import ChannelHistoryModel "../../models/channel-history-model";
import AgentModel "../../models/agent-model";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import InstructionComposer "../../instructions/instruction-composer";
import InstructionTypes "../../instructions/instruction-types";
import FunctionToolRegistry "../../tools/function-tool-registry";
import McpToolRegistry "../../tools/mcp-tool-registry";
import ToolExecutor "../../tools/tool-executor";
import ToolTypes "../../tools/tool-types";
import AgentHelpers "../helpers";
import ContextAssembler "../context-assembler";
import WorkspaceModel "../../models/workspace-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import EventStoreModel "../../models/event-store-model";
import SessionModel "../../models/session-model";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  /// All org-admin data the org-admin agent needs at execution time.
  /// Carries the full workspace state so the agent can list, create,
  /// and configure workspaces and their channel anchors.
  /// Also carries the agent registry so the agent can register and manage agents.
  public type AdminCtx = {
    workspaces : WorkspaceModel.WorkspacesState;
    agentRegistry : AgentModel.AgentRegistryState;
    // Resolved Slack user identity — used for authorization checks in write tools
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;
    // Encrypted secrets store — used by secrets-management tools
    secrets : SecretModel.SecretsState;
    // Key derivation cache — passed to StoreSecretHandler for encryption
    keyCache : KeyDerivationService.KeyCache;
    // Event store — used by event queue management tools
    eventStore : EventStoreModel.EventStoreState;
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
  /// `channelHistory` + `channelId` + `threadTs` provide channel/thread context for LLM.
  /// Tool call / tool response messages are ephemeral and never written to the store.
  public func process(
    agent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
    ctx : AdminCtx,
    apiKey : Text,
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
  ) : async ProcessResult {
    let steps : List.List<Types.ProcessingStep> = List.empty();

    // Extract model string from the agent's executionType
    let modelText = switch (agent.executionType) {
      case (#api({ model })) { model };
      case (#runtime(_)) { "" }; // unreachable for #api agents
    };

    // Build instructions driven by agent configuration
    let instructions = buildInstructions(agent);

    // Derive the org key so we can build a platform-secret resolver closure.
    // The closure captures secrets state, org key, and caller identity — tools
    // call it on-demand and each access is audit-logged.
    let orgKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, 0);
    let slackUserId : ?Text = switch (ctx.userAuthContext) {
      case (?uac) { ?uac.slackUserId };
      case (null) { null };
    };
    let slackBotTokenResolver = func(operation : Text) : ?Text {
      SecretModel.resolvePlatformSecret(
        ctx.secrets,
        orgKey,
        ?#admin,
        #slackBotToken,
        {
          slackUserId;
          agentId = ?agent.id;
          operation;
        },
      );
    };

    // Build tool resources — workspace-management, agent registry, and MCP tool management
    let toolResources : ToolTypes.ToolResources = {
      workspaceId = null; // org-admin tools operate on entire WorkspacesState, not a single workspace
      openRouterApiKey = ?apiKey;
      resolveSlackBotToken = ?slackBotTokenResolver;
      userAuthContext = ctx.userAuthContext;
      valueStreams = null;
      metrics = null;
      objectives = null;
      workspaces = ?{
        state = ctx.workspaces;
        write = true;
      };
      agentRegistry = ?{
        state = ctx.agentRegistry;
        write = true;
      };
      mcpToolRegistry = ?{
        state = mcpToolRegistry;
        write = true;
      };
      secrets = ?{
        state = ctx.secrets;
        keyCache = ctx.keyCache;
        write = true;
      };
      eventStore = ?{
        state = ctx.eventStore;
        write = true;
      };
      sessionStores = ?{
        stores = sessionStores;
        write = true;
      };
    };

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions(toolResources);
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);

    // Apply blocklist filtering via the public helper
    let filteredTools = AgentHelpers.applyToolBlocklist(agent, allTools);

    let toolsOpt : ?[OpenRouterWrapper.Tool] = if (filteredTools.size() == 0) null else ?filteredTools;

    // Assemble LLM context from session memory, turn digests, and channel/thread history.
    // Tool call / tool response artifacts are appended to inputMessages during the
    // reasoning loop below but are NOT written to the channel history store — they are
    // ephemeral and discarded when this function returns.
    let assembled = ContextAssembler.assemble(sessionStores, agent.id, turnId, channelHistory, channelId, threadTs);
    let inputMessages = List.fromArray<OpenRouterWrapper.ResponseInputMessage>(assembled.messages);

    var iteration = 0;

    loop {
      // openRouterApiKey is used as the model key; org-admin context is workspace-0 scoped
      let llmStartNs = Time.now();
      let llmResult = await OpenRouterWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        modelText,
        #workspace(0),
        ?instructions,
        null,
        toolsOpt,
      );
      let llmDurationMs : Nat = Int.abs(Time.now() - llmStartNs) / 1_000_000;

      switch (llmResult) {
        case (#ok(#textResponse({ content = response; thinking }))) {
          List.add(
            steps,
            {
              action = "llm_text_response";
              result = #ok;
              timestamp = Time.now();
            },
          );
          let maxTruncChars = SessionModel.getOrCreateSession(sessionStores, agent.id).policy.maxTruncatedTokens * 4;
          SessionModel.appendTrace(sessionStores, turnId, #llmCall({ model = modelText; durationMs = llmDurationMs; finishReason = "stop"; content = ?response; truncatedContent = ?TextUtils.truncateMiddle(response, maxTruncChars); thinking; toolRequests = null; cost = { promptTokens = 0; completionTokens = 0; estimatedMicroUnits = 0 } }));
          return #ok({ response; steps = List.toArray(steps) });
        };

        case (#ok(#toolCalls(calls))) {
          // Emit llmCall trace for the tool-calling response
          let toolReqs = Array.map<OpenRouterWrapper.ToolCall, { name : Text; input : Text }>(
            calls,
            func(c) { { name = c.toolName; input = c.arguments } },
          );
          SessionModel.appendTrace(sessionStores, turnId, #llmCall({ model = modelText; durationMs = llmDurationMs; finishReason = "tool_calls"; content = null; truncatedContent = null; thinking = null; toolRequests = ?toolReqs; cost = { promptTokens = 0; completionTokens = 0; estimatedMicroUnits = 0 } }));

          // Format tool call message (ephemeral — not written to channel history store)
          let toolCallContent = "Using tools: " # Array.foldLeft<OpenRouterWrapper.ToolCall, Text>(
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

          // Add individual execution steps and emit traces for each tool
          for (i in Array.keys(toolResults)) {
            let toolName = calls[i].toolName;
            let (stepResult, toolOutput, toolSuccess) : ({ #ok; #err : Text }, Text, Bool) = switch (toolResults[i].result) {
              case (#success(s)) { (#ok, s, true) };
              case (#error(msg)) { (#err(msg), msg, false) };
            };
            List.add(
              steps,
              {
                action = "tool_execution_" # toolName;
                result = stepResult;
                timestamp = Time.now();
              },
            );
            let maxTruncChars = SessionModel.getOrCreateSession(sessionStores, agent.id).policy.maxTruncatedTokens * 4;
            SessionModel.appendTrace(sessionStores, turnId, #toolCall({ name = toolName; input = calls[i].arguments; output = toolOutput; truncatedOutput = ?TextUtils.truncateMiddle(toolOutput, maxTruncChars); success = toolSuccess; durationMs = toolResults[i].durationMs }));
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
            SessionModel.appendTrace(sessionStores, turnId, #roundLimitHit);
            return #err({ message = errMsg; steps = List.toArray(steps) });
          };
          // Continue loop
        };

        case (#err(error)) {
          let errMsg = "OpenRouter API Error: " # error;
          List.add(
            steps,
            {
              action = "llm_api_error";
              result = #err(errMsg);
              timestamp = Time.now();
            },
          );
          SessionModel.appendTrace(sessionStores, turnId, #faultRecovered({ error = errMsg }));
          return #err({ message = errMsg; steps = List.toArray(steps) });
        };
      };
    };
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
