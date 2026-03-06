import Array "mo:core/Array";
import List "mo:core/List";
import GroqWrapper "../wrappers/groq-wrapper";
import ToolTypes "./tool-types";
import ValueStreamModel "../models/value-stream-model";
import MetricModel "../models/metric-model";
import ObjectiveModel "../models/objective-model";
import WorkspaceModel "../models/workspace-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import SaveValueStreamHandler "./handlers/save-value-stream-handler";
import SavePlanHandler "./handlers/save-plan-handler";
import ListWorkspacesHandler "./handlers/list-workspaces-handler";
import CreateWorkspaceHandler "./handlers/create-workspace-handler";
import SetWorkspaceAdminChannelHandler "./handlers/set-workspace-admin-channel-handler";
import SetWorkspaceMemberChannelHandler "./handlers/set-workspace-member-channel-handler";
import WebSearchHandler "./handlers/web-search-handler";
import CreateMetricHandler "./handlers/create-metric-handler";
import UpdateMetricHandler "./handlers/update-metric-handler";
import GetMetricDatapointsHandler "./handlers/get-metric-datapoints-handler";
import ListMetricsHandler "./handlers/list-metrics-handler";
import GetMetricHandler "./handlers/get-metric-handler";
import DeleteMetricHandler "./handlers/delete-metric-handler";
import GetLatestMetricDatapointHandler "./handlers/get-latest-metric-datapoint-handler";
import RecordMetricDatapointHandler "./handlers/record-metric-datapoint-handler";
import CreateObjectiveHandler "./handlers/create-objective-handler";
import UpdateObjectiveHandler "./handlers/update-objective-handler";
import ArchiveObjectiveHandler "./handlers/archive-objective-handler";
import RecordObjectiveDatapointHandler "./handlers/record-objective-datapoint-handler";
import AddImpactReviewHandler "./handlers/add-impact-review-handler";

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
    definition : GroqWrapper.Tool;
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
    // WEB SEARCH TOOL - requires groqApiKey
    // ==========================================
    switch (resources.groqApiKey) {
      case (?apiKey) {
        List.add(tools, webSearchTool(apiKey));
      };
      case (null) {};
    };

    // ==========================================
    // VALUE STREAM TOOLS - require workspaceId + valueStreams with write access
    // ==========================================
    switch (resources.workspaceId, resources.valueStreams) {
      case (?wsId, ?vs) {
        if (vs.write) {
          List.add(tools, saveValueStreamTool(wsId, vs.map));
          List.add(tools, savePlanTool(wsId, vs.map));
        };
        // Future: if read access, add getValueStreamsTool
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
    // OBJECTIVE TOOLS - require workspaceId + objectives with write access
    // ==========================================
    switch (resources.workspaceId, resources.objectives) {
      case (?wsId, ?obj) {
        if (obj.write) {
          List.add(tools, createObjectiveTool(wsId, obj.map));
          List.add(tools, updateObjectiveTool(wsId, obj.map));
          List.add(tools, archiveObjectiveTool(wsId, obj.map));
          List.add(tools, recordObjectiveDatapointTool(wsId, obj.map));
          List.add(tools, addImpactReviewTool(wsId, obj.map));
        };
        // Future: if read access, add read-only objective tools
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
    // ADD NEW TOOL CATEGORIES BELOW
    // ==========================================

    List.toArray(tools);
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions(resources : ToolTypes.ToolResources) : [GroqWrapper.Tool] {
    Array.map<FunctionTool, GroqWrapper.Tool>(
      getAll(resources),
      func(t : FunctionTool) : GroqWrapper.Tool { t.definition },
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

  /// Web search tool - requires groqApiKey
  private func webSearchTool(apiKey : Text) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "web_search";
          description = ?"Performs a web search using Groq's compound model with built-in search capabilities. Returns AI-analyzed search results with reasoning. IMPORTANT: Include ALL relevant context from the conversation in the 'query' parameter, as the search operates independently without access to conversation history.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The search query with full context. Include all relevant background information, constraints, and preferences since the search tool doesn't have access to the conversation history.\"},\"exclude_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Optional. Domains to exclude from search results. Supports wildcards like '*.example.com'.\"},\"include_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Optional. Restrict search to only these domains. Supports wildcards.\"},\"country\":{\"type\":\"string\",\"description\":\"Optional. ISO country code to boost results from (e.g., 'us', 'uk', 'de').\"}},\"required\":[\"query\"]}";
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
};
