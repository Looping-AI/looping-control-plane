import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Map "mo:core/Map";
import Iter "mo:core/Iter";
import Float "mo:core/Float";
import ConversationModel "../models/conversation-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import GroqWrapper "../wrappers/groq-wrapper";
import Constants "../constants";
import InstructionComposer "../instructions/instruction-composer";
import InstructionTypes "../instructions/instruction-types";
import FunctionToolRegistry "../tools/function-tool-registry";
import McpToolRegistry "../tools/mcp-tool-registry";
import ToolExecutor "../tools/tool-executor";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Execute admin talk using Groq LLM with multi-turn tool support
  public func executeAdminTalk(
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistry : MetricModel.MetricsRegistry,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    apiKey : Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Build instructions with workspace-specific context
    let instructions = buildAdminInstructions(
      workspaceValueStreamsState,
      workspaceObjectivesMap,
      metricsRegistry,
      metricDatapoints,
      workspaceId,
    );

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions();
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);
    let toolsOpt : ?[GroqWrapper.Tool] = if (allTools.size() == 0) null else ?allTools;

    // Multi-turn loop for tool execution
    // Build conversation history as array of messages
    let inputMessages = List.empty<GroqWrapper.ResponseInputMessage>();
    List.add(inputMessages, { role = #user; content = message });
    var iteration = 0;

    loop {
      let groqResult = await GroqWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        Constants.ADMIN_TALK_MODEL,
        #workspace(workspaceId),
        ?instructions,
        null,
        toolsOpt,
      );

      switch (groqResult) {
        case (#ok(#textResponse(response))) {
          // Final response - store conversation and return
          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            {
              author = #user;
              content = message;
              timestamp = Time.now();
            },
          );

          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            {
              author = #agent;
              content = response;
              timestamp = Time.now();
            },
          );

          return #ok(response);
        };

        case (#ok(#toolCalls(calls))) {
          // Execute tool calls
          let toolResults = await ToolExecutor.execute(mcpToolRegistry, calls);

          // Add assistant message indicating tool calls were made
          List.add(
            inputMessages,
            {
              role = #assistant;
              content = "Using tools: " # Array.foldLeft<GroqWrapper.ToolCall, Text>(
                calls,
                "",
                func(acc, call) {
                  if (acc == "") call.toolName else acc # ", " # call.toolName;
                },
              );
            },
          );

          // Add tool results as user message
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

  // Build workspace context blocks from ValueStreams, Objectives, and Metrics
  private func buildWorkspaceContext(
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistry : MetricModel.MetricsRegistry,
    metricDatapoints : MetricModel.MetricDatapointsStore,
  ) : [InstructionTypes.InstructionBlock] {
    var blocks : List.List<InstructionTypes.InstructionBlock> = List.empty();

    // Add metrics summary with latest datapoints
    let allMetrics = MetricModel.listMetrics(metricsRegistry);
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
    let (_, valueStreamsMap) = workspaceValueStreamsState;
    let streams = Iter.toArray(Map.values(valueStreamsMap));
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
          acc # "- [" # statusText # "] " # vs.name # "\n" #
          "  Problem: " # vs.problem # "\n" #
          "  Goal: " # vs.goal # "\n";
        },
      );
      List.add(blocks, { id = "workspace-value-streams"; content = streamsText });
    };

    // Add objectives for all value streams in this workspace
    var objectivesText = "Objectives:\n";
    var hasObjectives = false;

    for ((vsId, (_, valueStreamObjMap)) in Map.entries(workspaceObjectivesMap)) {
      let objectives = Iter.toArray(Map.values(valueStreamObjMap));
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
          objectivesText := objectivesText # "- [" # statusText # "] " # obj.name # " (" # typeText # ")\n";
          switch (obj.description) {
            case (?desc) {
              objectivesText := objectivesText # "  Description: " # desc # "\n";
            };
            case (null) {};
          };
        };
      };
    };

    if (hasObjectives) {
      List.add(blocks, { id = "workspace-objectives"; content = objectivesText });
    };

    List.toArray(blocks);
  };

  // Build admin instructions with context-aware layers
  private func buildAdminInstructions(
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistry : MetricModel.MetricsRegistry,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    _workspaceId : Nat,
  ) : Text {
    // Build workspace context from data
    let workspaceContext = buildWorkspaceContext(
      workspaceValueStreamsState,
      workspaceObjectivesMap,
      metricsRegistry,
      metricDatapoints,
    );

    // Determine which context layers to include based on workspace state
    var contextIds : List.List<InstructionTypes.ContextId> = List.empty();

    // Check if workspace needs value stream setup
    let (_, valueStreamsMap) = workspaceValueStreamsState;
    let streams = Iter.toArray(Map.values(valueStreamsMap));
    let hasActiveStream = Array.any<ValueStreamModel.ValueStream>(
      streams,
      func(vs) { vs.status == #active },
    );

    if (not hasActiveStream) {
      List.add(contextIds, #needsValueStreamSetup);
    };

    // Compose instructions with appropriate context layers
    InstructionComposer.compose(
      #workspaceAdmin,
      List.toArray(contextIds),
      workspaceContext,
    );
  };
};
