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
import ToolTypes "../tools/tool-types";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Maximum number of previous conversation messages to include as context
  let MAX_CONVERSATION_HISTORY : Nat = 30;

  // Execute admin talk using Groq LLM with multi-turn tool support
  public func executeAdminTalk(
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistry : MetricModel.MetricsRegistry,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    apiKey : Text,
  ) : async {
    #ok : [ConversationModel.Message];
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

    // Build tool resources - controls which tools are available
    let toolResources : ToolTypes.ToolResources = {
      workspaceId = ?workspaceId;
      groqApiKey = ?apiKey;
      valueStreams = ?{
        map = valueStreamsMap;
        write = true;
      };
      // Future: add objectives, metrics, etc.
    };

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions(toolResources);
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);
    let toolsOpt : ?[GroqWrapper.Tool] = if (allTools.size() == 0) null else ?allTools;

    // Track messages added during this conversation turn
    var newMessages = List.empty<ConversationModel.Message>();

    // Store user message in conversation history
    ConversationModel.addMessageToAdminConversation(
      adminConversations,
      workspaceId,
      {
        author = #user;
        content = message;
        timestamp = Time.now();
      },
    );

    // Load conversation history (bounded to last 30 messages) and convert to input format
    let inputMessages = loadConversationHistory(adminConversations, workspaceId);
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
          let agentMessage : ConversationModel.Message = {
            author = #agent;
            content = response;
            timestamp = Time.now();
          };
          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            agentMessage,
          );
          List.add(newMessages, agentMessage);

          return #ok(List.toArray(newMessages));
        };

        case (#ok(#toolCalls(calls))) {
          // Format tool call message
          let toolCallContent = "Using tools: " # Array.foldLeft<GroqWrapper.ToolCall, Text>(
            calls,
            "",
            func(acc, call) {
              if (acc == "") call.toolName else acc # ", " # call.toolName;
            },
          );

          // Add assistant message indicating tool calls were made
          List.add(
            inputMessages,
            {
              role = #assistant;
              content = toolCallContent;
            },
          );

          // Store tool call message in conversation history
          let toolCallMessage : ConversationModel.Message = {
            author = #tool_call;
            content = toolCallContent;
            timestamp = Time.now();
          };
          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            toolCallMessage,
          );
          List.add(newMessages, toolCallMessage);

          // Execute tool calls
          let toolResults = await ToolExecutor.execute(toolResources, mcpToolRegistry, calls);

          // Add tool results as user message
          let formattedResults = ToolExecutor.formatResultsForLlm(toolResults);
          List.add(inputMessages, { role = #assistant; content = formattedResults });

          // Store tool results in conversation history
          let toolResponseMessage : ConversationModel.Message = {
            author = #tool_response;
            content = formattedResults;
            timestamp = Time.now();
          };
          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            toolResponseMessage,
          );
          List.add(newMessages, toolResponseMessage);

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

  // Load conversation history and convert to input messages format
  // Bounds to MAX_CONVERSATION_HISTORY most recent messages
  private func loadConversationHistory(
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceId : Nat,
  ) : List.List<GroqWrapper.ResponseInputMessage> {
    // Load existing conversation history for this workspace
    let existingConversation = switch (Map.get(adminConversations, Nat.compare, workspaceId)) {
      case (null) { List.empty<ConversationModel.Message>() };
      case (?conv) { conv };
    };

    // Convert to array and determine starting index for bounded history
    let conversationArray = List.toArray(existingConversation);
    let historyStartIndex = if (conversationArray.size() > MAX_CONVERSATION_HISTORY) {
      Nat.sub(conversationArray.size(), MAX_CONVERSATION_HISTORY);
    } else {
      0;
    };

    // Convert bounded history to ResponseInputMessage format
    // Include tool calls and responses to provide full context to LLM
    let inputMessages = List.empty<GroqWrapper.ResponseInputMessage>();
    var i = historyStartIndex;
    while (i < conversationArray.size()) {
      let msg = conversationArray[i];
      let role : GroqWrapper.MessageRole = switch (msg.author) {
        case (#user) { #user };
        case (#agent) { #assistant };
        case (#tool_call) { #assistant };
        case (#tool_response) { #assistant };
      };
      List.add(inputMessages, { role; content = msg.content });
      i += 1;
    };

    inputMessages;
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
    } else {
      // Check if any active value stream needs a plan
      let hasActiveStreamWithoutPlan = Array.any<ValueStreamModel.ValueStream>(
        streams,
        func(vs) { vs.status == #active and vs.plan == null },
      );

      if (hasActiveStreamWithoutPlan) {
        List.add(contextIds, #needsPlanCreation);
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
