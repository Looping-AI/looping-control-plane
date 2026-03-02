import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import Iter "mo:core/Iter";
import Float "mo:core/Float";
import Time "mo:core/Time";
import ConversationModel "../models/conversation-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import GroqWrapper "../wrappers/groq-wrapper";
import InstructionComposer "../instructions/instruction-composer";
import InstructionTypes "../instructions/instruction-types";
import FunctionToolRegistry "../tools/function-tool-registry";
import McpToolRegistry "../tools/mcp-tool-registry";
import ToolExecutor "../tools/tool-executor";
import ToolTypes "../tools/tool-types";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Maximum number of previous conversation messages to include as context
  let MAX_CONVERSATION_HISTORY : Nat = 30;

  // Execute admin talk using Groq LLM with multi-turn tool support.
  //
  // `conversationEntry` carries the timeline entry for LLM context (Phase 1.4).
  // Pass `null` when calling from the legacy direct endpoint (no persistent history).
  // Tool call / tool response messages are ephemeral and never written to the store.
  public func executeAdminTalk(
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    conversationEntry : ?ConversationModel.TimelineEntry,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    apiKey : Text,
    model : Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Build instructions with workspace-specific context
    let instructions = buildAdminInstructions(
      workspaceValueStreamsState,
      workspaceObjectivesMap,
      metricsRegistryState,
      metricDatapoints,
      workspaceId,
    );

    // Build tool resources - controls which tools are available
    let toolResources : ToolTypes.ToolResources = {
      workspaceId = ?workspaceId;
      groqApiKey = ?apiKey;
      valueStreams = ?{
        map = valueStreamsMap;
        write = true;
      };
      metrics = ?{
        registryState = metricsRegistryState;
        datapoints = metricDatapoints;
        write = true;
      };
      objectives = ?{
        map = workspaceObjectivesMap;
        write = true;
      };
    };

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions(toolResources);
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);
    let toolsOpt : ?[GroqWrapper.Tool] = if (allTools.size() == 0) null else ?allTools;

    // Build LLM context from persistent conversation history (Phase 1.4).
    // Tool call / tool response artifacts are appended to inputMessages during the
    // reasoning loop below but are NOT written to the conversation store — they are
    // ephemeral and discarded when this function returns.
    let inputMessages = buildContextMessages(conversationEntry);

    // Add the new user message
    List.add(inputMessages, { role = #user; content = message });

    var iteration = 0;

    loop {
      let groqResult = await GroqWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        model,
        #workspace(workspaceId),
        ?instructions,
        null,
        toolsOpt,
      );

      switch (groqResult) {
        case (#ok(#textResponse(response))) {
          return #ok(response);
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

          // Append tool results to in-memory input for the next LLM round
          let formattedResults = ToolExecutor.formatResultsForLlm(toolResults);
          List.add(inputMessages, { role = #assistant; content = formattedResults });

          iteration += 1;
          if (iteration >= MAX_ITERATIONS) {
            return #err("Max tool iterations reached (" # Nat.toText(MAX_ITERATIONS) # ")");
          };
          // Continue loop
        };

        case (#err(error)) {
          return #err("Groq API Error: " # error);
        };
      };
    };
  };

  // Build LLM input messages from a TimelineEntry (conversation history).
  //
  // Role mapping:
  //   ConversationMessage.userAuthContext = null  → #assistant  (bot/agent message)
  //   ConversationMessage.userAuthContext = ?_    → #user       (human message)
  //
  // For a #post: a single message is added.
  // For a #thread: the last MAX_CONVERSATION_HISTORY messages are added.
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
          let role : GroqWrapper.MessageRole = switch (msg.userAuthContext) {
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

  // Build workspace context blocks from ValueStreams, Objectives, and Metrics
  private func buildWorkspaceContext(
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
  ) : [InstructionTypes.InstructionBlock] {
    var blocks : List.List<InstructionTypes.InstructionBlock> = List.empty();

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
    var contextIdsText = "";
    var hasObjectives = false;
    var needsAttention = List.empty<Text>();
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
      contextIdsText := "⚠️ Objectives Needing Attention:\n" # Array.foldLeft<Text, Text>(
        List.toArray(needsAttention),
        "",
        func(acc, item) { acc # item # "\n" },
      );
      List.add(blocks, { id = "objectives-attention"; content = contextIdsText });
    };

    List.toArray(blocks);
  };

  // Build admin instructions with context-aware layers
  private func buildAdminInstructions(
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

    // Determine which context layers to include based on workspace state
    var contextIds : List.List<InstructionTypes.ContextId> = List.empty();

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

    // Compose instructions with appropriate context layers
    InstructionComposer.compose(
      #workspaceAdmin,
      List.toArray(contextIds),
      workspaceContext,
    );
  };
};
