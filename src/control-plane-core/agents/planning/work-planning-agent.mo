import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import Iter "mo:core/Iter";
import Float "mo:core/Float";
import Time "mo:core/Time";
import Text "mo:core/Text";
import Types "../../types";
import ConversationModel "../../models/conversation-model";
import ValueStreamModel "../../models/value-stream-model";
import ObjectiveModel "../../models/objective-model";
import MetricModel "../../models/metric-model";
import AgentModel "../../models/agent-model";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import InstructionComposer "../../instructions/instruction-composer";
import InstructionTypes "../../instructions/instruction-types";
import FunctionToolRegistry "../../tools/function-tool-registry";
import McpToolRegistry "../../tools/mcp-tool-registry";
import ToolExecutor "../../tools/tool-executor";
import ToolTypes "../../tools/tool-types";
import AgentHelpers "../helpers";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Maximum number of previous conversation messages to include as context
  let MAX_CONVERSATION_HISTORY : Nat = 30;

  /// All planning-domain data the work-planning agent needs at execution time.
  /// Scoped to a single workspace — the caller (MessageHandler via AgentRouter/Orchestrator)
  /// extracts the relevant workspace slice from `EventProcessingContext` before dispatch.
  public type PlanningCtx = {
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState;
    valueStreamsMap : ValueStreamModel.ValueStreamsMap;
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap;
    metricsRegistryState : MetricModel.MetricsRegistryState;
    metricDatapoints : MetricModel.MetricDatapointsStore;
    workspaceId : Nat;
  };

  /// ProcessResult mirrors the OrgAdminAgent return type so the orchestrator can use
  /// a shared result type across all agents.
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

  /// Process a message using the work-planning agent configuration.
  ///
  /// `agent` drives persona, tool filtering, and knowledge sources.
  /// `ctx` carries the workspace-scoped planning data (value streams, metrics, objectives).
  /// `conversationEntry` carries the timeline entry for LLM context.
  /// Pass `null` when no persistent history exists.
  /// Tool call / tool response messages are ephemeral and never written to the store.
  public func process(
    agent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    conversationEntry : ?ConversationModel.TimelineEntry,
    ctx : PlanningCtx,
    message : Text,
    apiKey : Text,
  ) : async ProcessResult {
    let steps : List.List<Types.ProcessingStep> = List.empty();

    // Extract model string from the agent's executionType
    let modelText = switch (agent.executionType) {
      case (#api({ model })) { model };
      case (#runtime(_)) { "" }; // unreachable for #api agents
    };

    // Build instructions driven by agent configuration
    let instructions = buildInstructions(
      agent,
      ctx.workspaceValueStreamsState,
      ctx.workspaceObjectivesMap,
      ctx.metricsRegistryState,
      ctx.metricDatapoints,
      ctx.workspaceId,
    );

    // Build tool resources — workspace-management tools are not available to this agent
    let toolResources : ToolTypes.ToolResources = {
      workspaceId = ?ctx.workspaceId;
      openRouterApiKey = ?apiKey;
      resolveSlackBotToken = null;
      userAuthContext = null;
      valueStreams = ?{
        map = ctx.valueStreamsMap;
        write = true;
      };
      metrics = ?{
        registryState = ctx.metricsRegistryState;
        datapoints = ctx.metricDatapoints;
        write = true;
      };
      objectives = ?{
        map = ctx.workspaceObjectivesMap;
        write = true;
      };
      workspaces = null; // planning agent does not manage workspace channel anchors
      agentRegistry = null; // planning agent does not manage agent registry
      mcpToolRegistry = null; // planning agent does not manage MCP tool registry
      secrets = null; // planning agent does not manage secrets
      eventStore = null; // planning agent does not manage event store
    };

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions(toolResources);
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);

    // Apply blocklist filtering via the public helper
    let filteredTools = AgentHelpers.applyToolBlocklist(agent, allTools);

    let toolsOpt : ?[OpenRouterWrapper.Tool] = if (filteredTools.size() == 0) null else ?filteredTools;

    // Build LLM context from persistent conversation history.
    // Tool call / tool response artifacts are appended to inputMessages during the
    // reasoning loop below but are NOT written to the conversation store — they are
    // ephemeral and discarded when this function returns.
    let inputMessages = buildContextMessages(conversationEntry);

    // Add the new user message
    List.add(inputMessages, { role = #user; content = message });

    var iteration = 0;

    loop {
      let llmResult = await OpenRouterWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        modelText,
        #workspace(ctx.workspaceId),
        ?instructions,
        null,
        toolsOpt,
      );

      switch (llmResult) {
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
          let errMsg = "OpenRouter API Error: " # error;
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
  ///
  /// For a #post: a single message is added.
  /// For a #thread: the last MAX_CONVERSATION_HISTORY messages are added.
  private func buildContextMessages(
    conversationEntry : ?ConversationModel.TimelineEntry
  ) : List.List<OpenRouterWrapper.ResponseInputMessage> {
    let inputMessages = List.empty<OpenRouterWrapper.ResponseInputMessage>();
    switch (conversationEntry) {
      case (null) { /* no history — start fresh */ };
      case (?#post msg) {
        let role : OpenRouterWrapper.MessageRole = switch (msg.userAuthContext) {
          case (null) { #assistant };
          case (?_) { #user };
        };
        List.add(inputMessages, { role; content = msg.text });
      };
      case (?#thread thread) {
        // Map.toArray returns entries sorted by ts (lexicographic = chronological)
        let messagesArr = Map.toArray(thread.messages); // [(ts, ConversationMessage)]
        let startIndex = if (messagesArr.size() > MAX_CONVERSATION_HISTORY) {
          Nat.sub(messagesArr.size(), MAX_CONVERSATION_HISTORY);
        } else {
          0;
        };
        var i = startIndex;
        while (i < messagesArr.size()) {
          let (_, msg) = messagesArr[i];
          let role : OpenRouterWrapper.MessageRole = switch (msg.userAuthContext) {
            case (null) { #assistant }; // bot message
            case (?_) { #user }; // user message
          };
          List.add(inputMessages, { role; content = msg.text });
          i += 1;
        };
      };
    };
    inputMessages;
  };

  /// Build workspace context blocks from ValueStreams, Objectives, and Metrics
  private func buildWorkspaceContext(
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
  ) : [InstructionTypes.InstructionBlock] {
    let blocks : List.List<InstructionTypes.InstructionBlock> = List.empty();

    // Add metrics summary with latest datapoints
    let allMetrics = MetricModel.listMetrics(metricsRegistryState);
    if (allMetrics.size() > 0) {
      let metricsText = Array.foldLeft<MetricModel.MetricRegistration, Text>(
        allMetrics,
        "Available Metrics:\n",
        func(acc, m) {
          let latestDatapoint = MetricModel.getLatestDatapoint(metricDatapoints, m.id);
          let latestValue = switch (latestDatapoint) {
            case (?dp) { " (latest: " # Float.toText(dp.value) # ")" };
            case (null) { "" };
          };
          acc # "- " # m.name # " (" # m.unit # "): " # m.description # latestValue # "\n";
        },
      );
      List.add(blocks, { id = "workspace-metrics"; content = metricsText });
    };

    // Add value streams for this workspace
    let streams = Iter.toArray(Map.values(workspaceValueStreamsState.valueStreams));
    if (streams.size() > 0) {
      let streamsText = Array.foldLeft<ValueStreamModel.ValueStream, Text>(
        streams,
        "Value Streams:\n",
        func(acc, vs) {
          let statusText = switch (vs.status) {
            case (#draft) "draft";
            case (#active) "active";
            case (#paused) "paused";
            case (#archived) "archived";
          };
          let planStatus = switch (vs.plan) {
            case (null) " [no plan]";
            case (?p) " [has plan: " # p.summary # "]";
          };
          acc # "- [" # statusText # "] " # vs.name # " (ID: " # Nat.toText(vs.id) # ")" # planStatus # "\n" #
          "  Problem: " # vs.problem # "\n" #
          "  Goal: " # vs.goal # "\n";
        },
      );
      List.add(blocks, { id = "workspace-value-streams"; content = streamsText });
    };

    // Add objectives for all value streams in this workspace
    var objectivesText = "Objectives:\n";
    var hasObjectives = false;
    let needsAttention = List.empty<Text>();
    let now = Time.now();

    for ((vsId, vsObjectivesState) in Map.entries(workspaceObjectivesMap)) {
      let objectives = Iter.toArray(Map.values(vsObjectivesState.objectives));
      if (objectives.size() > 0) {
        hasObjectives := true;
        for (obj in objectives.vals()) {
          let typeText = switch (obj.objectiveType) {
            case (#target) "target";
            case (#contributing) "contributing";
            case (#prerequisite) "prerequisite";
            case (#guardrail) "guardrail";
          };
          let statusText = switch (obj.status) {
            case (#active) "active";
            case (#paused) "paused";
            case (#archived) "archived";
          };

          // Build current vs target display
          let progressText = switch (obj.current, obj.target) {
            case (?current, #percentage({ target })) {
              " | Current: " # Float.toText(current) # "%, Target: " # Float.toText(target) # "%";
            };
            case (?current, #count({ target; direction })) {
              let dir = switch (direction) {
                case (#increase) "↑";
                case (#decrease) "↓";
              };
              " | Current: " # Float.toText(current) # ", Target: " # Float.toText(target) # " " # dir;
            };
            case (?current, #threshold({ min; max })) {
              let range = switch (min, max) {
                case (?minVal, ?maxVal) {
                  Float.toText(minVal) # "-" # Float.toText(maxVal);
                };
                case (?minVal, null) { "≥" # Float.toText(minVal) };
                case (null, ?maxVal) { "≤" # Float.toText(maxVal) };
                case (null, null) { "no bounds" };
              };
              " | Current: " # Float.toText(current) # ", Range: " # range;
            };
            case (?current, #boolean(target)) {
              " | Current: " # (if (current == 1.0) "true" else "false") # ", Target: " # (if (target) "true" else "false");
            };
            case (null, _) { " | No data yet" };
          };

          objectivesText := objectivesText # "- [" # statusText # "] " # obj.name # " (" # typeText # ", VS:" # Nat.toText(vsId) # ", ID:" # Nat.toText(obj.id) # ")" # progressText # "\n";

          switch (obj.description) {
            case (?desc) {
              objectivesText := objectivesText # "  Description: " # desc # "\n";
            };
            case (null) {};
          };

          // Check if needs attention (past target date or no recent updates)
          switch (obj.targetDate) {
            case (?targetDate) {
              if (targetDate < now and obj.status == #active) {
                List.add(needsAttention, "- Objective '" # obj.name # "' (VS:" # Nat.toText(vsId) # ", ID:" # Nat.toText(obj.id) # ") is past its target date. Consider an impact review and updating targets if continuing.");
              };
            };
            case (null) {};
          };
        };
      };
    };

    if (hasObjectives) {
      List.add(blocks, { id = "workspace-objectives"; content = objectivesText });
    };

    // Add context IDs for objectives needing attention
    if (List.size(needsAttention) > 0) {
      let attentionText = "⚠️ Objectives Needing Attention:\n" # Array.foldLeft<Text, Text>(
        List.toArray(needsAttention),
        "",
        func(acc, item) { acc # item # "\n" },
      );
      List.add(blocks, { id = "objectives-attention"; content = attentionText });
    };

    List.toArray(blocks);
  };

  /// Build instructions with context-aware layers, driven by agent configuration.
  ///
  /// The agent role is derived from `agent.category` via `categoryToRole`.
  /// If `agent.sources` is non-empty, an `"agent-sources"` block is appended
  /// listing each source URL/ref on its own line (prefixed with `- `).
  private func buildInstructions(
    agent : AgentModel.AgentRecord,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    _workspaceId : Nat,
  ) : Text {
    // Build workspace context from data
    let workspaceContext = buildWorkspaceContext(
      workspaceValueStreamsState,
      workspaceObjectivesMap,
      metricsRegistryState,
      metricDatapoints,
    );

    // Append sources block if the agent has knowledge sources (use public helper)
    let customBlocks : [InstructionTypes.InstructionBlock] = if (agent.sources.size() > 0) {
      Array.concat(workspaceContext, AgentHelpers.sourceBlocks(agent));
    } else {
      workspaceContext;
    };

    // Determine which context layers to include based on workspace state
    let contextIds : List.List<InstructionTypes.ContextId> = List.empty();

    // Check if workspace needs value stream setup
    let streams = Iter.toArray(Map.values(workspaceValueStreamsState.valueStreams));
    let hasActiveStream = Array.any<ValueStreamModel.ValueStream>(
      streams,
      func(vs) { vs.status == #active },
    );

    if (not hasActiveStream) {
      List.add(contextIds, #needsValueStreamSetup);
    } else {
      // Check if any active value stream needs a plan
      let hasActiveStreamWithoutPlan = Array.any<ValueStreamModel.ValueStream>(
        streams,
        func(vs) { vs.status == #active and vs.plan == null },
      );

      if (hasActiveStreamWithoutPlan) {
        List.add(contextIds, #needsPlanCreation);
      } else {
        // At least one active stream has plans
        // Check if metrics review is warranted
        List.add(contextIds, #needsMetricsReview);
      };
    };

    // Compose instructions with the role derived from agent category
    InstructionComposer.compose(
      AgentHelpers.categoryToRole(agent.category, agent.name),
      List.toArray(contextIds),
      customBlocks,
    );
  };

};
