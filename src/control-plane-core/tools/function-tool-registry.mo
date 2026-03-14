import Array "mo:core/Array";
import List "mo:core/List";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";
import ValueStreamModel "../models/value-stream-model";
import MetricModel "../models/metric-model";
import ObjectiveModel "../models/objective-model";
import WorkspaceModel "../models/workspace-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import SaveValueStreamHandler "./handlers/value-streams/save-value-stream-handler";
import SavePlanHandler "./handlers/save-plan-handler";
import ListValueStreamsHandler "./handlers/value-streams/list-value-streams-handler";
import GetValueStreamHandler "./handlers/value-streams/get-value-stream-handler";
import DeleteValueStreamHandler "./handlers/value-streams/delete-value-stream-handler";
import ListWorkspacesHandler "./handlers/workspaces/list-workspaces-handler";
import CreateWorkspaceHandler "./handlers/workspaces/create-workspace-handler";
import SetWorkspaceAdminChannelHandler "./handlers/workspaces/set-workspace-admin-channel-handler";
import SetWorkspaceMemberChannelHandler "./handlers/workspaces/set-workspace-member-channel-handler";
import WebSearchHandler "./handlers/web-search-handler";
import CreateMetricHandler "./handlers/metrics/create-metric-handler";
import UpdateMetricHandler "./handlers/metrics/update-metric-handler";
import GetMetricDatapointsHandler "./handlers/metrics/get-metric-datapoints-handler";
import ListMetricsHandler "./handlers/metrics/list-metrics-handler";
import GetMetricHandler "./handlers/metrics/get-metric-handler";
import DeleteMetricHandler "./handlers/metrics/delete-metric-handler";
import GetLatestMetricDatapointHandler "./handlers/metrics/get-latest-metric-datapoint-handler";
import RecordMetricDatapointHandler "./handlers/metrics/record-metric-datapoint-handler";
import CreateObjectiveHandler "./handlers/objectives/create-objective-handler";
import UpdateObjectiveHandler "./handlers/objectives/update-objective-handler";
import ArchiveObjectiveHandler "./handlers/objectives/archive-objective-handler";
import RecordObjectiveDatapointHandler "./handlers/objectives/record-objective-datapoint-handler";
import AddImpactReviewHandler "./handlers/objectives/add-impact-review-handler";
import ListObjectivesHandler "./handlers/objectives/list-objectives-handler";
import GetObjectiveHandler "./handlers/objectives/get-objective-handler";
import GetObjectiveHistoryHandler "./handlers/objectives/get-objective-history-handler";
import AddObjectiveDatapointCommentHandler "./handlers/objectives/add-objective-datapoint-comment-handler";
import GetImpactReviewsHandler "./handlers/objectives/get-impact-reviews-handler";
import RegisterAgentHandler "./handlers/agents/register-agent-handler";
import ListAgentsHandler "./handlers/agents/list-agents-handler";
import GetAgentHandler "./handlers/agents/get-agent-handler";
import UpdateAgentHandler "./handlers/agents/update-agent-handler";
import ForkAgentHandler "./handlers/agents/fork-agent-handler";
import UnregisterAgentHandler "./handlers/agents/unregister-agent-handler";
import RegisterMcpToolHandler "./handlers/mcp/register-mcp-tool-handler";
import UnregisterMcpToolHandler "./handlers/mcp/unregister-mcp-tool-handler";
import ListMcpToolsHandler "./handlers/mcp/list-mcp-tools-handler";
import StoreSecretHandler "./handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "./handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "./handlers/secrets/delete-secret-handler";
import GetEventStoreStatsHandler "./handlers/events/get-event-store-stats-handler";
import GetFailedEventsHandler "./handlers/events/get-failed-events-handler";
import DeleteFailedEventsHandler "./handlers/events/delete-failed-events-handler";
import AgentModel "../models/agent-model";
import McpToolRegistry "./mcp-tool-registry";
import SecretModel "../models/secret-model";
import KeyDerivationService "../services/key-derivation-service";
import EventStoreModel "../models/event-store-model";

module {
  // ============================================
  // Function Tool Registry
  // ============================================
  //
  // Resource-based registry of function tools.
  // Tools are generated dynamically based on provided resources,
  // creating a natural allowlist mechanism.
  //
  // Each tool has its definition (what LLM sees) and handler (implementation).
  // Handlers are closures over provided resources.
  //
  // To add a new tool:
  // 1. Create a private function that returns FunctionTool
  // 2. Capture required resources in the closure
  // 3. Add it to getAll() with appropriate resource checks
  //
  // ============================================

  /// A function tool with definition and implementation
  public type FunctionTool = {
    definition : OpenRouterWrapper.Tool;
    handler : (Text) -> async Text;
  };

  /// Get all registered function tools available for the given resources
  public func getAll(resources : ToolTypes.ToolResources) : [FunctionTool] {
    let tools = List.empty<FunctionTool>();

    // ==========================================
    // ECHO TOOL (for testing) - always available
    // ==========================================
    List.add(tools, echoTool());

    // ==========================================
    // WEB SEARCH TOOL - requires openRouterApiKey
    // ==========================================
    switch (resources.openRouterApiKey) {
      case (?apiKey) {
        List.add(tools, webSearchTool(apiKey));
      };
      case (null) {};
    };

    // ==========================================
    // VALUE STREAM TOOLS - require workspaceId + valueStreams
    // ==========================================
    switch (resources.workspaceId, resources.valueStreams) {
      case (?wsId, ?vs) {
        // Read tools — always available when resource is present
        List.add(tools, listValueStreamsTool(wsId, vs.map));
        List.add(tools, getValueStreamTool(wsId, vs.map));
        // Write tools — require write access
        if (vs.write) {
          List.add(tools, saveValueStreamTool(wsId, vs.map));
          List.add(tools, savePlanTool(wsId, vs.map));
          // Delete also cleans up objectives; only wire when objectives map is available
          switch (resources.objectives) {
            case (?obj) {
              List.add(tools, deleteValueStreamTool(wsId, vs.map, obj.map));
            };
            case (null) {};
          };
        };
      };
      case _ {};
    };

    // ==========================================
    // METRIC TOOLS - require metrics resource
    // ==========================================
    switch (resources.metrics) {
      case (?m) {
        // Read tools — always available when resource is present
        List.add(tools, listMetricsTool(m.registryState));
        List.add(tools, getMetricTool(m.registryState));
        List.add(tools, getMetricDatapointsTool(m.registryState, m.datapoints));
        List.add(tools, getLatestMetricDatapointTool(m.registryState, m.datapoints));
        // Write tools — require write access
        if (m.write) {
          List.add(tools, createMetricTool(m.registryState));
          List.add(tools, updateMetricTool(m.registryState));
          List.add(tools, recordMetricDatapointTool(m.registryState, m.datapoints));
          List.add(tools, deleteMetricTool(m.registryState, m.datapoints));
        };
      };
      case (null) {};
    };

    // ==========================================
    // OBJECTIVE TOOLS - require workspaceId + objectives resource
    // ==========================================
    switch (resources.workspaceId, resources.objectives) {
      case (?wsId, ?obj) {
        // Read tools — always available when resource is present
        List.add(tools, listObjectivesTool(wsId, obj.map));
        List.add(tools, getObjectiveTool(wsId, obj.map));
        List.add(tools, getObjectiveHistoryTool(wsId, obj.map));
        List.add(tools, getImpactReviewsTool(wsId, obj.map));
        // Write tools — require write access
        if (obj.write) {
          List.add(tools, createObjectiveTool(wsId, obj.map));
          List.add(tools, updateObjectiveTool(wsId, obj.map));
          List.add(tools, archiveObjectiveTool(wsId, obj.map));
          List.add(tools, recordObjectiveDatapointTool(wsId, obj.map));
          List.add(tools, addImpactReviewTool(wsId, obj.map));
          List.add(tools, addObjectiveDatapointCommentTool(wsId, obj.map));
        };
      };
      case _ {};
    };

    // ==========================================
    // WORKSPACE TOOLS - require workspaces resource
    // ==========================================
    switch (resources.workspaces) {
      case (?ws) {
        // Read tools — always available when resource is present
        List.add(tools, listWorkspacesTool(ws.state));
        // Write tools — require write=true AND a resolved user identity AND a Slack bot token
        // (the token is needed for channel verification; the identity for authorization)
        switch (resources.userAuthContext, resources.slackBotToken) {
          case (?uac, ?botToken) {
            if (ws.write) {
              List.add(tools, createWorkspaceTool(ws.state, uac));
              List.add(tools, setWorkspaceAdminChannelTool(ws.state, uac, botToken));
              List.add(tools, setWorkspaceMemberChannelTool(ws.state, uac, botToken));
            };
          };
          case _ {};
        };
      };
      case (null) {};
    };

    // ==========================================
    // AGENT REGISTRY TOOLS - require agentRegistry resource
    // ==========================================
    switch (resources.agentRegistry) {
      case (?ar) {
        // Read tools — always available when resource is present
        List.add(tools, listAgentsTool(ar.state));
        List.add(tools, getAgentTool(ar.state));
        // Write tools — require write access and a resolved user identity
        switch (resources.userAuthContext) {
          case (?uac) {
            if (ar.write) {
              List.add(tools, registerAgentTool(ar.state, uac));
              List.add(tools, updateAgentTool(ar.state, uac));
              List.add(tools, forkAgentTool(ar.state, uac));
              List.add(tools, unregisterAgentTool(ar.state, uac));
            };
          };
          case (null) {};
        };
      };
      case (null) {};
    };

    // ==========================================
    // MCP TOOL MANAGEMENT TOOLS - require mcpToolRegistry resource
    // ==========================================
    switch (resources.mcpToolRegistry) {
      case (?mcp) {
        // Read tools — always available when resource is present
        List.add(tools, listMcpToolsTool(mcp.state));
        // Write tools — require write=true AND a resolved user identity
        if (mcp.write) {
          switch (resources.userAuthContext) {
            case (?uac) {
              List.add(tools, registerMcpToolTool(mcp.state, uac));
              List.add(tools, unregisterMcpToolTool(mcp.state, uac));
            };
            case (null) {};
          };
        };
      };
      case (null) {};
    };

    // ==========================================
    // SECRETS MANAGEMENT TOOLS - require secrets resource + userAuthContext
    // ==========================================
    switch (resources.secrets, resources.userAuthContext) {
      case (?sec, ?uac) {
        // Read tools — always available when resource and user identity are present
        List.add(tools, getWorkspaceSecretsTool(sec.state, uac));
        // Write tools — require write=true
        if (sec.write) {
          // store_secret additionally needs workspaces resource for workspace existence check
          switch (resources.workspaces) {
            case (?ws) {
              List.add(tools, storeSecretTool(sec.state, sec.keyCache, ws.state, uac));
            };
            case (null) {};
          };
          List.add(tools, deleteSecretTool(sec.state, uac));
        };
      };
      case _ {};
    };

    // ==========================================
    // EVENT STORE TOOLS - require eventStore resource + userAuthContext
    // ==========================================
    switch (resources.eventStore, resources.userAuthContext) {
      case (?es, ?uac) {
        // Read tools — always available when resource and user identity are present
        List.add(tools, getEventStoreStatsTool(es.state, uac));
        List.add(tools, getFailedEventsTool(es.state, uac));
        // Write tools — require write=true
        if (es.write) {
          List.add(tools, deleteFailedEventsTool(es.state, uac));
        };
      };
      case _ {};
    };

    List.toArray(tools);
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions(resources : ToolTypes.ToolResources) : [OpenRouterWrapper.Tool] {
    Array.map<FunctionTool, OpenRouterWrapper.Tool>(
      getAll(resources),
      func(t : FunctionTool) : OpenRouterWrapper.Tool { t.definition },
    );
  };

  /// Lookup a function tool by name (with resources for closures)
  public func get(resources : ToolTypes.ToolResources, name : Text) : ?FunctionTool {
    Array.find<FunctionTool>(
      getAll(resources),
      func(t : FunctionTool) : Bool {
        t.definition.function.name == name;
      },
    );
  };

  // ============================================
  // PRIVATE TOOL IMPLEMENTATIONS
  // ============================================

  /// Echo tool - no resources required
  private func echoTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "echo";
          description = ?"Echoes back the input message. Useful for testing.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"The message to echo back\"}},\"required\":[\"message\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        // Simply return the arguments as-is
        args;
      };
    };
  };

  /// List value streams tool - requires workspaceId + valueStreams (read)
  private func listValueStreamsTool(workspaceId : Nat, valueStreamsMap : ValueStreamModel.ValueStreamsMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_value_streams";
          description = ?"Lists all value streams in the current workspace showing their IDs, names, problems, goals, statuses, and whether a plan exists.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListValueStreamsHandler.handle(workspaceId, valueStreamsMap, args);
      };
    };
  };

  /// Get value stream tool - requires workspaceId + valueStreams (read)
  private func getValueStreamTool(workspaceId : Nat, valueStreamsMap : ValueStreamModel.ValueStreamsMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_value_stream";
          description = ?"Gets the full details of a value stream by ID, including its plan if one exists.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream to retrieve\"}},\"required\":[\"valueStreamId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetValueStreamHandler.handle(workspaceId, valueStreamsMap, args);
      };
    };
  };

  /// Delete value stream tool - requires workspaceId + valueStreams with write + objectives
  private func deleteValueStreamTool(
    workspaceId : Nat,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_value_stream";
          description = ?"Permanently deletes a value stream and all its objectives. This action cannot be undone. Use only when the value stream is no longer needed.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream to delete\"}},\"required\":[\"valueStreamId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteValueStreamHandler.handle(workspaceId, valueStreamsMap, workspaceObjectivesMap, args);
      };
    };
  };

  /// Save value stream tool - requires workspaceId + valueStreams with write
  private func saveValueStreamTool(workspaceId : Nat, valueStreamsMap : ValueStreamModel.ValueStreamsMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "save_value_stream";
          description = ?"Creates a new value stream or updates an existing one. Use this after refining the problem and goal with the user.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"Optional. If provided, updates existing stream.\"},\"name\":{\"type\":\"string\",\"description\":\"Name of the value stream\"},\"problem\":{\"type\":\"string\",\"description\":\"The problem being solved\"},\"goal\":{\"type\":\"string\",\"description\":\"The desired outcome\"},\"activate\":{\"type\":\"boolean\",\"description\":\"Optional. Set to true to activate the stream (set status to active). Defaults to false (status will be draft).\"}},\"required\":[\"name\",\"problem\",\"goal\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await SaveValueStreamHandler.handle(workspaceId, valueStreamsMap, args);
      };
    };
  };

  /// Save plan tool - requires workspaceId + valueStreams with write
  private func savePlanTool(workspaceId : Nat, valueStreamsMap : ValueStreamModel.ValueStreamsMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "save_plan";
          description = ?"Saves or updates a plan for a value stream. Use this ONLY after user has explicitly confirmed they are satisfied with the final plan.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"The ID of the value stream to plan for\"},\"summary\":{\"type\":\"string\",\"description\":\"One-paragraph overview of the approach\"},\"currentState\":{\"type\":\"string\",\"description\":\"Where things are today (problems, constraints)\"},\"targetState\":{\"type\":\"string\",\"description\":\"Where we want to be (specific, measurable)\"},\"steps\":{\"type\":\"string\",\"description\":\"High-level phases or milestones (not detailed tasks)\"},\"risks\":{\"type\":\"string\",\"description\":\"Key risks and mitigation strategies\"},\"resources\":{\"type\":\"string\",\"description\":\"What's needed (people, tools, budget, knowledge)\"}},\"required\":[\"valueStreamId\",\"summary\",\"currentState\",\"targetState\",\"steps\",\"risks\",\"resources\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await SavePlanHandler.handle(workspaceId, valueStreamsMap, args);
      };
    };
  };

  // ============================================
  // WORKSPACE TOOL IMPLEMENTATIONS
  // ============================================

  /// List workspaces tool — always available when workspaces resource is present
  private func listWorkspacesTool(state : WorkspaceModel.WorkspacesState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_workspaces";
          description = ?"Lists all workspace records including their IDs, names, and Slack channel anchors (admin and member channel IDs). Workspace 0 is the org workspace; its admin channel is also the org-admin channel.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListWorkspacesHandler.handle(state, args);
      };
    };
  };

  /// Create workspace tool — requires workspaces resource with write
  private func createWorkspaceTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "create_workspace";
          description = ?"Creates a new workspace with the given name. Workspace names must be unique. Returns the new workspace ID.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name for the new workspace. Must be unique across all workspaces.\"}},\"required\":[\"name\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await CreateWorkspaceHandler.handle(state, uac, args);
      };
    };
  };

  /// Set workspace admin channel tool — requires workspaces resource with write
  private func setWorkspaceAdminChannelTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    botToken : Text,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "set_workspace_admin_channel";
          description = ?"Sets the Slack channel whose members become admins of the given workspace. For workspace 0 (the org workspace) this also anchors the org-admin channel. Channel IDs must be globally unique across all workspace anchors.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to configure.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Slack channel ID (e.g. 'C01234567') to set as the admin channel.\"}},\"required\":[\"workspaceId\",\"channelId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await SetWorkspaceAdminChannelHandler.handle(state, uac, botToken, args);
      };
    };
  };

  /// Set workspace member channel tool — requires workspaces resource with write
  private func setWorkspaceMemberChannelTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    botToken : Text,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "set_workspace_member_channel";
          description = ?"Sets the Slack channel whose members become members of the given workspace. Channel IDs must be globally unique across all workspace anchors.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to configure.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Slack channel ID (e.g. 'C01234567') to set as the member channel.\"}},\"required\":[\"workspaceId\",\"channelId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await SetWorkspaceMemberChannelHandler.handle(state, uac, botToken, args);
      };
    };
  };

  /// Web search tool - requires openRouterApiKey
  private func webSearchTool(apiKey : Text) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "web_search";
          description = ?"Performs a web search using the OpenRouter web search plugin. Returns AI-analyzed search results. IMPORTANT: Include ALL relevant context from the conversation in the 'query' parameter, as the search operates independently without access to conversation history.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The search query with full context. Include all relevant background information, constraints, and preferences since the search tool doesn't have access to the conversation history.\"}},\"required\":[\"query\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await WebSearchHandler.handle(apiKey, args);
      };
    };
  };

  // ============================================
  // METRIC TOOLS
  // ============================================

  /// Create metric tool - requires registryState with write access
  private func createMetricTool(registryState : MetricModel.MetricsRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "create_metric";
          description = ?"Register a new metric for tracking progress. Metrics measure specific aspects of value streams and objectives. Use this to define what should be measured, not to record actual measurements.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Unique name for the metric (e.g., 'Monthly Active Users', 'Response Time')\"},\"description\":{\"type\":\"string\",\"description\":\"Clear description of what this metric measures and why it matters\"},\"unit\":{\"type\":\"string\",\"description\":\"Unit of measurement (e.g., 'count', 'USD', 'percent', 'seconds', 'milliseconds')\"},\"retentionDays\":{\"type\":\"integer\",\"description\":\"How long to retain datapoints (30-1825 days). Use 90 for short-term, 365 for annual, 1825 for 5-year history.\"}},\"required\":[\"name\",\"description\",\"unit\",\"retentionDays\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await CreateMetricHandler.handle(registryState, args);
      };
    };
  };

  /// Update metric tool - requires registryState with write access
  private func updateMetricTool(registryState : MetricModel.MetricsRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "update_metric";
          description = ?"Update an existing metric's configuration. Cannot modify actual datapoints - only the metric definition (name, description, unit, retention). Use this to refine metric definitions or fix mistakes.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric to update\"},\"name\":{\"type\":\"string\",\"description\":\"New name for the metric (optional)\"},\"description\":{\"type\":\"string\",\"description\":\"New description (optional)\"},\"unit\":{\"type\":\"string\",\"description\":\"New unit of measurement (optional)\"},\"retentionDays\":{\"type\":\"integer\",\"description\":\"New retention period in days, 30-1825 (optional)\"}},\"required\":[\"metricId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UpdateMetricHandler.handle(registryState, args);
      };
    };
  };

  /// Get metric datapoints tool - read access sufficient
  private func getMetricDatapointsTool(
    registryState : MetricModel.MetricsRegistryState,
    datapoints : MetricModel.MetricDatapointsStore,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_metric_datapoints";
          description = ?"Retrieve datapoint history for a metric. Use this to analyze trends, check current values, or understand metric behavior. Returns datapoints sorted by timestamp (newest first).";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric\"},\"since\":{\"type\":\"string\",\"description\":\"Optional ISO timestamp to filter datapoints from (e.g., '2026-01-01T00:00:00Z'). Only returns datapoints after this time.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Optional maximum number of recent datapoints to return (default: all)\"}},\"required\":[\"metricId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetMetricDatapointsHandler.handle(registryState, datapoints, args);
      };
    };
  };

  /// List metrics tool - read access sufficient
  private func listMetricsTool(registryState : MetricModel.MetricsRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_metrics";
          description = ?"Lists all registered metrics with their IDs, names, descriptions, units, and retention settings.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListMetricsHandler.handle(registryState, args);
      };
    };
  };

  /// Get metric tool - read access sufficient
  private func getMetricTool(registryState : MetricModel.MetricsRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_metric";
          description = ?"Gets a single metric's full definition by its ID. Use this to confirm details before recording datapoints or updating a metric.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric to retrieve\"}},\"required\":[\"metricId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetMetricHandler.handle(registryState, args);
      };
    };
  };

  /// Get latest metric datapoint tool - read access sufficient
  private func getLatestMetricDatapointTool(
    registryState : MetricModel.MetricsRegistryState,
    datapoints : MetricModel.MetricDatapointsStore,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_latest_metric_datapoint";
          description = ?"Gets the most recent datapoint for a metric. Useful for quickly checking the current value without fetching the full history.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric\"}},\"required\":[\"metricId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetLatestMetricDatapointHandler.handle(registryState, datapoints, args);
      };
    };
  };

  /// Record metric datapoint tool - requires write access
  private func recordMetricDatapointTool(
    registryState : MetricModel.MetricsRegistryState,
    datapoints : MetricModel.MetricDatapointsStore,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "record_metric_datapoint";
          description = ?"Records a new datapoint (measurement) for a metric. Use this when the user provides a new measurement or you compute a value from available data.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric\"},\"value\":{\"type\":\"number\",\"description\":\"The measured value to record\"},\"sourceType\":{\"type\":\"string\",\"enum\":[\"manual\",\"integration\",\"evaluator\",\"other\"],\"description\":\"Optional. How the value was obtained. Defaults to 'manual'.\"},\"sourceLabel\":{\"type\":\"string\",\"description\":\"Optional. Label identifying the source of the measurement (e.g. 'admin', 'api', 'assistant'). Defaults to 'assistant'.\"}},\"required\":[\"metricId\",\"value\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await RecordMetricDatapointHandler.handle(registryState, datapoints, args);
      };
    };
  };

  /// Delete metric tool - requires write access
  private func deleteMetricTool(
    registryState : MetricModel.MetricsRegistryState,
    datapoints : MetricModel.MetricDatapointsStore,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_metric";
          description = ?"Permanently deletes a metric and all its historical datapoints. This action cannot be undone. Use only when the metric is no longer needed and its history can be discarded.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"metricId\":{\"type\":\"integer\",\"description\":\"The ID of the metric to delete\"}},\"required\":[\"metricId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteMetricHandler.handle(registryState, datapoints, args);
      };
    };
  };

  // ============================================
  // OBJECTIVE TOOLS
  // ============================================

  /// List objectives tool - read access sufficient
  private func listObjectivesTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_objectives";
          description = ?"Lists all objectives for a value stream, including their current values, targets, and status.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream to list objectives for\"}},\"required\":[\"valueStreamId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListObjectivesHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Get objective tool - read access sufficient
  private func getObjectiveTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_objective";
          description = ?"Gets the full details of a single objective by ID, including its target definition, current value, and status.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective to retrieve\"}},\"required\":[\"valueStreamId\",\"objectiveId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetObjectiveHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Get objective history tool - read access sufficient
  private func getObjectiveHistoryTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_objective_history";
          description = ?"Returns the full datapoint history for an objective in chronological order. Use this to review progress over time or before adding a comment to a specific entry.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective\"}},\"required\":[\"valueStreamId\",\"objectiveId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetObjectiveHistoryHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Get impact reviews tool - read access sufficient
  private func getImpactReviewsTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_impact_reviews";
          description = ?"Returns all impact reviews for an objective. Use this to understand the history of perceived impact assessments before adding a new review.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective\"}},\"required\":[\"valueStreamId\",\"objectiveId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetImpactReviewsHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Add objective datapoint comment tool - requires write access
  private func addObjectiveDatapointCommentTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "add_objective_datapoint_comment";
          description = ?"Adds a comment to a specific datapoint in an objective's history. Use get_objective_history first to confirm the correct historyIndex (0 = oldest entry).";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective\"},\"historyIndex\":{\"type\":\"number\",\"description\":\"Index of the history entry to comment on (0 = oldest)\"},\"message\":{\"type\":\"string\",\"description\":\"The comment text\"},\"author\":{\"type\":\"string\",\"description\":\"Optional. Author name for the comment. Defaults to 'assistant'\"}},\"required\":[\"valueStreamId\",\"objectiveId\",\"historyIndex\",\"message\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await AddObjectiveDatapointCommentHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Create objective tool - requires workspaceId + objectives with write
  private func createObjectiveTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "create_objective";
          description = ?"Creates a new objective for a value stream. Use this after discussing and confirming the objective details with the user. An objective tracks progress toward a specific target using one or more metrics.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream this objective belongs to\"},\"name\":{\"type\":\"string\",\"description\":\"Name of the objective\"},\"description\":{\"type\":\"string\",\"description\":\"Optional. Detailed description of what this objective measures\"},\"objectiveType\":{\"type\":\"string\",\"enum\":[\"target\",\"contributing\",\"prerequisite\",\"guardrail\"],\"description\":\"Role of this objective: target (main success metric), contributing (supports target), prerequisite (blocks progress if not met), guardrail (maintain threshold)\"},\"metricIds\":{\"type\":\"array\",\"items\":{\"type\":\"number\"},\"description\":\"Array of metric IDs this objective uses for computation\"},\"computation\":{\"type\":\"string\",\"description\":\"Formula or description of how to compute the objective value from metrics\"},\"targetType\":{\"type\":\"string\",\"enum\":[\"percentage\",\"count\",\"threshold\",\"boolean\"],\"description\":\"Type of target to achieve\"},\"targetValue\":{\"type\":\"number\",\"description\":\"Target value (for percentage, count, or threshold min/max)\"},\"targetDirection\":{\"type\":\"string\",\"enum\":[\"increase\",\"decrease\"],\"description\":\"For count targets: should the value increase or decrease?\"},\"targetMax\":{\"type\":\"number\",\"description\":\"For threshold targets: maximum acceptable value\"},\"targetBoolean\":{\"type\":\"boolean\",\"description\":\"For boolean targets: desired true/false state\"},\"targetDate\":{\"type\":\"number\",\"description\":\"Optional. Unix timestamp (nanoseconds) when target should be achieved\"}},\"required\":[\"valueStreamId\",\"name\",\"objectiveType\",\"metricIds\",\"computation\",\"targetType\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await CreateObjectiveHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Update objective tool - requires workspaceId + objectives with write
  private func updateObjectiveTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "update_objective";
          description = ?"Updates an existing objective. Can modify any field except the id. Use this to adjust targets, change status, or update descriptions based on user feedback.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective to update\"},\"name\":{\"type\":\"string\",\"description\":\"Optional. New name\"},\"description\":{\"type\":\"string\",\"description\":\"Optional. New description (use empty string to clear)\"},\"clearDescription\":{\"type\":\"boolean\",\"description\":\"Optional. Set to true to clear the description\"},\"objectiveType\":{\"type\":\"string\",\"enum\":[\"target\",\"contributing\",\"prerequisite\",\"guardrail\"],\"description\":\"Optional. New objective type\"},\"metricIds\":{\"type\":\"array\",\"items\":{\"type\":\"number\"},\"description\":\"Optional. New array of metric IDs\"},\"computation\":{\"type\":\"string\",\"description\":\"Optional. New computation formula\"},\"targetType\":{\"type\":\"string\",\"enum\":[\"percentage\",\"count\",\"threshold\",\"boolean\"],\"description\":\"Optional. New target type\"},\"targetValue\":{\"type\":\"number\",\"description\":\"Optional. New target value\"},\"targetDirection\":{\"type\":\"string\",\"enum\":[\"increase\",\"decrease\"],\"description\":\"Optional. For count targets\"},\"targetMax\":{\"type\":\"number\",\"description\":\"Optional. For threshold targets\"},\"targetBoolean\":{\"type\":\"boolean\",\"description\":\"Optional. For boolean targets\"},\"targetDate\":{\"type\":\"number\",\"description\":\"Optional. New target date (Unix timestamp in nanoseconds)\"},\"clearTargetDate\":{\"type\":\"boolean\",\"description\":\"Optional. Set to true to clear the target date\"},\"status\":{\"type\":\"string\",\"enum\":[\"active\",\"paused\",\"archived\"],\"description\":\"Optional. New status\"}},\"required\":[\"valueStreamId\",\"objectiveId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UpdateObjectiveHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Archive objective tool - requires workspaceId + objectives with write
  private func archiveObjectiveTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "archive_objective";
          description = ?"Archives an objective by setting its status to archived. Use this when an objective is no longer relevant or has been achieved and should be preserved but not actively tracked.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective to archive\"}},\"required\":[\"valueStreamId\",\"objectiveId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ArchiveObjectiveHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Record objective datapoint tool - requires workspaceId + objectives with write
  private func recordObjectiveDatapointTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "record_objective_datapoint";
          description = ?"Records a new datapoint for an objective, updating both the current value and adding an entry to the history. Use this when the user provides a progress update or you calculate a new value based on metric data.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective\"},\"value\":{\"type\":\"number\",\"description\":\"The computed objective value\"},\"timestamp\":{\"type\":\"number\",\"description\":\"Optional. Unix timestamp in nanoseconds. Defaults to now if not provided\"},\"valueWarning\":{\"type\":\"string\",\"description\":\"Optional. A warning message if there were issues computing the value\"},\"comment\":{\"type\":\"string\",\"description\":\"Optional. A comment about this datapoint\"},\"commentAuthor\":{\"type\":\"string\",\"description\":\"Optional. Author of the comment (assistant name or 'user'). Defaults to 'assistant'\"}},\"required\":[\"valueStreamId\",\"objectiveId\",\"value\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await RecordObjectiveDatapointHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  /// Add impact review tool - requires workspaceId + objectives with write
  private func addImpactReviewTool(workspaceId : Nat, workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "add_impact_review";
          description = ?"Adds an impact review to assess whether an objective is still meaningful and making progress. Use this periodically or when requested to evaluate objective effectiveness, especially for objectives past their target date or showing little progress.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"ID of the value stream\"},\"objectiveId\":{\"type\":\"number\",\"description\":\"ID of the objective\"},\"perceivedImpact\":{\"type\":\"string\",\"enum\":[\"negative\",\"none\",\"low\",\"medium\",\"high\",\"unclear\"],\"description\":\"Assessment of the objective's perceived impact\"},\"comment\":{\"type\":\"string\",\"description\":\"Optional. Comments explaining the impact assessment\"},\"author\":{\"type\":\"string\",\"description\":\"Optional. Author of the review (assistant name). Defaults to 'assistant'\"}},\"required\":[\"valueStreamId\",\"objectiveId\",\"perceivedImpact\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await AddImpactReviewHandler.handle(workspaceId, workspaceObjectivesMap, args);
      };
    };
  };

  // ============================================
  // AGENT REGISTRY TOOL IMPLEMENTATIONS
  // ============================================

  /// List agents tool — always available when agentRegistry resource is present
  private func listAgentsTool(state : AgentModel.AgentRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_agents";
          description = ?"Lists all registered agents with their IDs, names, categories, LLM models, and configuration.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListAgentsHandler.handle(state, args);
      };
    };
  };

  /// Get agent tool — always available when agentRegistry resource is present
  private func getAgentTool(state : AgentModel.AgentRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_agent";
          description = ?"Looks up a registered agent by its ID (number) or name (string). Provide either 'id' or 'name'.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"Agent ID to look up.\"},\"name\":{\"type\":\"string\",\"description\":\"Agent name to look up (case-insensitive).\"}},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetAgentHandler.handle(state, args);
      };
    };
  };

  /// Register agent tool — requires agentRegistry resource with write + user identity
  private func registerAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "register_agent";
          description = ?"Registers a new agent in the global registry. The name must be unique, lowercase, start with a letter, and contain only letters, digits, and hyphens. Category must be one of: admin, planning, research, communication. Execution type must be specified (api or runtime with codespace hosting and openClaw framework).";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Agent identifier (kebab-case, e.g. 'work-planning').\"},\"category\":{\"type\":\"string\",\"enum\":[\"admin\",\"planning\",\"research\",\"communication\"],\"description\":\"Agent category.\"},\"workspaceId\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Workspace that will own the agent. Omit to default to org workspace (0).\"},\"llmModel\":{\"type\":\"string\",\"description\":\"LLM model to use. Currently: gpt_oss_120b. Omit to use the default.\"},\"executionType\":{\"type\":\"object\",\"description\":\"Execution type configuration (required).\",\"oneOf\":[{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"api\"]}},\"required\":[\"type\"]},{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"runtime\"]},\"hosting\":{\"type\":\"string\",\"enum\":[\"codespace\"]},\"framework\":{\"type\":\"string\",\"enum\":[\"openClaw\"]}},\"required\":[\"type\",\"hosting\",\"framework\"]}]},\"secretsAllowed\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\"},\"secretId\":{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"openaiApiKey\",\"slackBotToken\"]}},\"required\":[\"workspaceId\",\"secretId\"]},\"description\":\"Secrets this agent may access. Omit for empty list.\"},\"toolsDisallowed\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Tool names to block for this agent. Omit for none.\"},\"sources\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Knowledge source URLs or references for this agent. Omit for none.\"}},\"required\":[\"name\",\"category\",\"executionType\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await RegisterAgentHandler.handle(state, uac, args);
      };
    };
  };

  /// Update agent tool — requires agentRegistry resource with write + user identity
  private func updateAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "update_agent";
          description = ?"Updates an existing agent's configuration. Provide the agent 'id' and only the fields you want to change; omitted fields are left unchanged.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to update.\"},\"name\":{\"type\":\"string\",\"description\":\"New agent name (optional).\"},\"category\":{\"type\":\"string\",\"enum\":[\"admin\",\"planning\",\"research\",\"communication\"],\"description\":\"New category (optional).\"},\"llmModel\":{\"type\":\"string\",\"description\":\"New LLM model (optional). Currently: gpt_oss_120b.\"},\"executionType\":{\"type\":\"object\",\"description\":\"New execution type configuration (optional).\",\"oneOf\":[{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"api\"]}},\"required\":[\"type\"]},{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"runtime\"]},\"hosting\":{\"type\":\"string\",\"enum\":[\"codespace\"]},\"framework\":{\"type\":\"string\",\"enum\":[\"openClaw\"]}},\"required\":[\"type\",\"hosting\",\"framework\"]}]},\"secretsAllowed\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\"},\"secretId\":{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"openaiApiKey\",\"slackBotToken\"]}},\"required\":[\"workspaceId\",\"secretId\"]},\"description\":\"Replace the full secrets whitelist (optional). Pass [] to revoke all secret access.\"},\"toolsDisallowed\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"New tools blocklist (optional).\"},\"sources\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"New knowledge sources (optional).\"}},\"required\":[\"id\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UpdateAgentHandler.handle(state, uac, args);
      };
    };
  };

  /// Fork agent tool — requires agentRegistry resource with write + user identity
  private func forkAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "fork_agent";
          description = ?"Forks an existing agent into a new workspace. Inherits category, llmModel, toolsDisallowed, toolsState.knowHow, and sources. Resets usageCount and toolsMisconfigured. Secrets are workspace-scoped and must be provided explicitly for the new workspace.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"originalId\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"ID of the agent to fork from.\"},\"newName\":{\"type\":\"string\",\"description\":\"Name for the new agent (kebab-case).\"},\"targetWorkspaceId\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Workspace that will own the new agent.\"},\"secretsAllowed\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"integer\",\"minimum\":0},\"secretId\":{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"openaiApiKey\",\"slackBotToken\"]}},\"required\":[\"workspaceId\",\"secretId\"]},\"description\":\"Secrets for the new workspace. Omit for none.\"},\"executionType\":{\"type\":\"object\",\"description\":\"Override execution type. Omit to inherit from original.\",\"oneOf\":[{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"api\"]}},\"required\":[\"type\"]},{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"runtime\"]},\"hosting\":{\"type\":\"string\",\"enum\":[\"codespace\"]},\"framework\":{\"type\":\"string\",\"enum\":[\"openClaw\"]}},\"required\":[\"type\",\"hosting\",\"framework\"]}]}},\"required\":[\"originalId\",\"newName\",\"targetWorkspaceId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ForkAgentHandler.handle(state, uac, args);
      };
    };
  };

  /// Unregister agent tool — requires agentRegistry resource with write + user identity
  private func unregisterAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "unregister_agent";
          description = ?"Permanently removes an agent from the registry. This action cannot be undone. Any active sessions referencing this agent will fail after removal.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to unregister.\"}},\"required\":[\"id\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UnregisterAgentHandler.handle(state, uac, args);
      };
    };
  };

  // ============================================
  // MCP TOOL MANAGEMENT IMPLEMENTATIONS
  // ============================================

  /// List MCP tools tool — always available when mcpToolRegistry resource is present
  private func listMcpToolsTool(state : McpToolRegistry.McpToolRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_mcp_tools";
          description = ?"Lists all registered MCP tools including their names, descriptions, server IDs, and parameter schemas.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListMcpToolsHandler.handle(state, args);
      };
    };
  };

  /// Register MCP tool tool — requires mcpToolRegistry resource with write + user identity
  private func registerMcpToolTool(
    state : McpToolRegistry.McpToolRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "register_mcp_tool";
          description = ?"Registers a new MCP tool in the registry. The tool will be available for use in agent conversations. Tool names must be unique.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Unique tool name (used as the function name in tool calls)\"},\"description\":{\"type\":\"string\",\"description\":\"What this tool does\"},\"parameters\":{\"type\":\"string\",\"description\":\"JSON schema string for the tool's parameters (optional)\"},\"serverId\":{\"type\":\"string\",\"description\":\"ID of the MCP server that hosts this tool\"},\"remoteName\":{\"type\":\"string\",\"description\":\"Tool name on the remote server if different from the registered name (optional)\"}},\"required\":[\"name\",\"serverId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await RegisterMcpToolHandler.handle(state, uac, args);
      };
    };
  };

  /// Unregister MCP tool tool — requires mcpToolRegistry resource with write + user identity
  private func unregisterMcpToolTool(
    state : McpToolRegistry.McpToolRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "unregister_mcp_tool";
          description = ?"Removes an MCP tool from the registry by name. Returns whether the tool was found and removed.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name of the MCP tool to remove\"}},\"required\":[\"name\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UnregisterMcpToolHandler.handle(state, uac, args);
      };
    };
  };

  // ============================================
  // SECRETS MANAGEMENT TOOL IMPLEMENTATIONS
  // ============================================

  /// Get workspace secrets tool — always available when secrets resource + user identity are present
  private func getWorkspaceSecretsTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_workspace_secrets";
          description = ?"Lists the secret identifiers stored for a workspace. Secret values are never returned — only the names of which secrets have been stored.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to list secrets for.\"}},\"required\":[\"workspaceId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetWorkspaceSecretsHandler.handle(map, uac, args);
      };
    };
  };

  /// Store secret tool — requires secrets resource with write + workspaces resource + user identity
  private func storeSecretTool(
    map : SecretModel.SecretsState,
    keyCache : KeyDerivationService.KeyCache,
    workspacesState : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "store_secret";
          description = ?"Encrypts and stores a secret for a workspace. The Slack bot token (slackBotToken) requires org-admin access. LLM API keys (openRouterApiKey, openaiApiKey) can be stored by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to store the secret for.\"},\"secretId\":{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"openaiApiKey\",\"slackBotToken\"],\"description\":\"The type of secret to store.\"},\"secretValue\":{\"type\":\"string\",\"description\":\"The secret value to encrypt and store.\"}},\"required\":[\"workspaceId\",\"secretId\",\"secretValue\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await StoreSecretHandler.handle(map, keyCache, workspacesState, uac, args);
      };
    };
  };

  /// Delete secret tool — requires secrets resource with write + user identity
  private func deleteSecretTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_secret";
          description = ?"Removes a stored secret from a workspace. Slack secrets require org-admin access. LLM API keys can be deleted by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace.\"},\"secretId\":{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"openaiApiKey\",\"slackBotToken\"],\"description\":\"The type of secret to delete.\"}},\"required\":[\"workspaceId\",\"secretId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteSecretHandler.handle(map, uac, args);
      };
    };
  };

  // ============================================
  // EVENT STORE TOOL IMPLEMENTATIONS
  // ============================================

  /// Get event store stats tool — requires eventStore resource + user identity
  private func getEventStoreStatsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_event_store_stats";
          description = ?"Get event queue statistics: counts of unprocessed, processed, and failed events.";
          parameters = ?"{\"type\":\"object\",\"properties\":{}}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetEventStoreStatsHandler.handle(state, uac, args);
      };
    };
  };

  /// Get failed events tool — requires eventStore resource + user identity
  private func getFailedEventsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_failed_events";
          description = ?"List all failed events with their event IDs, error messages, and timestamps.";
          parameters = ?"{\"type\":\"object\",\"properties\":{}}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetFailedEventsHandler.handle(state, uac, args);
      };
    };
  };

  /// Delete failed events tool — requires eventStore resource with write + user identity
  private func deleteFailedEventsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_failed_events";
          description = ?"Delete failed event(s). Provide eventId to delete one specific event, or omit to delete all failed events.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"eventId\":{\"type\":\"string\",\"description\":\"ID of a specific failed event to delete (e.g. 'slack_Ev0123'). Omit to delete all failed events.\"}}}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteFailedEventsHandler.handle(state, uac, args);
      };
    };
  };
};
