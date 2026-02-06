import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Json "mo:json";
import { str; obj; int; float; bool; arr } "mo:json";
import GroqWrapper "../wrappers/groq-wrapper";
import ToolTypes "./tool-types";
import ValueStreamModel "../models/value-stream-model";
import MetricModel "../models/metric-model";
import ObjectiveModel "../models/objective-model";

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
        if (m.write) {
          List.add(tools, createMetricTool(m.registryState));
          List.add(tools, updateMetricTool(m.registryState));
        };
        // get_metric_datapoints available for read or write access
        List.add(tools, getMetricDatapointsTool(m.registryState, m.datapoints));
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

  /// Helper function to extract Nat array from JSON array
  private func extractNatArray(jsonArray : [Json.Json]) : [Nat] {
    let buffer = List.empty<Nat>();
    for (item in jsonArray.vals()) {
      switch (item) {
        case (#number(#int n)) {
          if (n >= 0) {
            List.add(buffer, Int.abs(n));
          };
        };
        case _ {};
      };
    };
    List.toArray(buffer);
  };

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
        // Parse JSON arguments
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract fields
            let idOpt : ?Nat = switch (Json.get(json, "id")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let nameOpt = switch (Json.get(json, "name")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let problemOpt = switch (Json.get(json, "problem")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let goalOpt = switch (Json.get(json, "goal")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let activateOpt = switch (Json.get(json, "activate")) {
              case (?#bool(b)) { ?b };
              case (_) { null };
            };

            // Validate required fields
            switch (nameOpt, problemOpt, goalOpt) {
              case (?name, ?problem, ?goal) {
                let activate = switch (activateOpt) {
                  case (?b) { b };
                  case (null) { false };
                };

                // Handle update vs create
                switch (idOpt) {
                  case (?id) {
                    // Update existing stream
                    let status = if (activate) { ?#active } else { null };
                    let result = ValueStreamModel.updateValueStream(
                      valueStreamsMap,
                      workspaceId,
                      id,
                      ?name,
                      ?problem,
                      ?goal,
                      status,
                    );

                    switch (result) {
                      case (#ok(())) {
                        buildSuccessResponse(id, "updated");
                      };
                      case (#err(msg)) {
                        buildErrorResponse(msg);
                      };
                    };
                  };
                  case (null) {
                    // Create new stream
                    let result = ValueStreamModel.createValueStream(
                      valueStreamsMap,
                      workspaceId,
                      { name; problem; goal },
                    );

                    switch (result) {
                      case (#ok(newId)) {
                        // If activate requested, update status
                        if (activate) {
                          let _ = ValueStreamModel.updateValueStream(
                            valueStreamsMap,
                            workspaceId,
                            newId,
                            null,
                            null,
                            null,
                            ?#active,
                          );
                        };
                        buildSuccessResponse(newId, "created");
                      };
                      case (#err(msg)) {
                        buildErrorResponse(msg);
                      };
                    };
                  };
                };
              };
              case (_) {
                buildErrorResponse("Missing required fields: name, problem, or goal");
              };
            };
          };
        };
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
        // Parse JSON arguments
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract all required fields
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            let summaryOpt = switch (Json.get(json, "summary")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let currentStateOpt = switch (Json.get(json, "currentState")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let targetStateOpt = switch (Json.get(json, "targetState")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let stepsOpt = switch (Json.get(json, "steps")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let risksOpt = switch (Json.get(json, "risks")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let resourcesOpt = switch (Json.get(json, "resources")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            // Validate all required fields
            switch (valueStreamIdOpt, summaryOpt, currentStateOpt, targetStateOpt, stepsOpt, risksOpt, resourcesOpt) {
              case (?valueStreamId, ?summary, ?currentState, ?targetState, ?steps, ?risks, ?resources) {
                let planInput : ValueStreamModel.PlanInput = {
                  summary;
                  currentState;
                  targetState;
                  steps;
                  risks;
                  resources;
                };

                let changedBy = #assistant("workspace-admin-ai");
                let diff = "Plan created/updated via save_plan tool";

                let result = ValueStreamModel.setPlan(
                  valueStreamsMap,
                  workspaceId,
                  valueStreamId,
                  planInput,
                  changedBy,
                  diff,
                );

                switch (result) {
                  case (#ok(())) {
                    Json.stringify(
                      obj([
                        ("success", #bool(true)),
                        ("valueStreamId", int(valueStreamId)),
                        ("action", str("plan_saved")),
                      ]),
                      null,
                    );
                  };
                  case (#err(msg)) {
                    buildErrorResponse(msg);
                  };
                };
              };
              case _ {
                buildErrorResponse("Missing required fields. All fields are required: valueStreamId, summary, currentState, targetState, steps, risks, resources");
              };
            };
          };
        };
      };
    };
  };

  // ============================================
  // HELPER FUNCTIONS
  // ============================================

  /// Build a success response JSON string
  private func buildSuccessResponse(id : Nat, action : Text) : Text {
    Json.stringify(
      obj([
        ("success", #bool(true)),
        ("id", int(id)),
        ("action", str(action)),
      ]),
      null,
    );
  };

  /// Build an error response JSON string
  private func buildErrorResponse(message : Text) : Text {
    Json.stringify(
      obj([
        ("success", #bool(false)),
        ("error", str(message)),
      ]),
      null,
    );
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
        // Parse JSON arguments
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract query (required)
            let searchQueryOpt = switch (Json.get(json, "query")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            switch (searchQueryOpt) {
              case (?searchQuery) {
                // Extract optional search settings
                let excludeDomains = switch (Json.get(json, "exclude_domains")) {
                  case (?#array(arr)) {
                    let domains = List.empty<Text>();
                    for (item in arr.vals()) {
                      switch (item) {
                        case (#string(s)) { List.add(domains, s) };
                        case (_) {};
                      };
                    };
                    let domainsArray = List.toArray(domains);
                    if (domainsArray.size() > 0) { ?domainsArray } else { null };
                  };
                  case (_) { null };
                };

                let includeDomains = switch (Json.get(json, "include_domains")) {
                  case (?#array(arr)) {
                    let domains = List.empty<Text>();
                    for (item in arr.vals()) {
                      switch (item) {
                        case (#string(s)) { List.add(domains, s) };
                        case (_) {};
                      };
                    };
                    let domainsArray = List.toArray(domains);
                    if (domainsArray.size() > 0) { ?domainsArray } else { null };
                  };
                  case (_) { null };
                };

                let country = switch (Json.get(json, "country")) {
                  case (?#string(s)) { ?s };
                  case (_) { null };
                };

                // Build search settings if any optional params provided
                let searchSettings : ?GroqWrapper.SearchSettings = if (excludeDomains != null or includeDomains != null or country != null) {
                  ?{
                    exclude_domains = excludeDomains;
                    include_domains = includeDomains;
                    country;
                  };
                } else {
                  null;
                };

                // Call Groq's compound model with web search
                let result = await GroqWrapper.useBuiltInTool(
                  apiKey,
                  searchQuery,
                  #web_search({ searchSettings }),
                );

                switch (result) {
                  case (#ok(response)) {
                    // Format the full compound response as JSON
                    // Include reasoning, search results, and AI response
                    switch (response.choices[0]) {
                      case (choice) {
                        let message = choice.message;

                        // Build search results array if present
                        let searchResultsJson = switch (message.executed_tools) {
                          case (?tools) {
                            let resultsArr = List.empty<Json.Json>();
                            for (tool in tools.vals()) {
                              switch (tool.search_results) {
                                case (?results) {
                                  for (result in results.vals()) {
                                    List.add(
                                      resultsArr,
                                      obj([
                                        ("title", str(result.title)),
                                        ("url", str(result.url)),
                                        ("content", str(result.content)),
                                        ("relevance_score", float(result.relevance_score)),
                                      ]),
                                    );
                                  };
                                };
                                case (null) {};
                              };
                            };
                            arr(List.toArray(resultsArr));
                          };
                          case (null) { arr([]) };
                        };

                        return Json.stringify(
                          obj([
                            ("success", bool(true)),
                            ("response", str(message.content)),
                            ("reasoning", str(switch (message.reasoning) { case (?r) { r }; case (null) { "" } })),
                            ("search_results", searchResultsJson),
                          ]),
                          null,
                        );
                      };
                    };
                  };
                  case (#err(error)) {
                    return buildErrorResponse("Web search failed: " # error);
                  };
                };
              };
              case (null) {
                return buildErrorResponse("Missing required field: query");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract required fields
            let nameOpt = switch (Json.get(json, "name")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let descriptionOpt = switch (Json.get(json, "description")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let unitOpt = switch (Json.get(json, "unit")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let retentionDaysOpt = switch (Json.get(json, "retentionDays")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            switch (nameOpt, descriptionOpt, unitOpt, retentionDaysOpt) {
              case (?name, ?description, ?unit, ?retentionDays) {
                let input : MetricModel.MetricRegistrationInput = {
                  name;
                  description;
                  unit;
                  retentionDays;
                };

                // Use anonymous principal for tool-created metrics
                let caller = Principal.fromText("2vxsx-fae");
                let result = MetricModel.registerMetric(
                  registryState,
                  input,
                  caller,
                  Time.now(),
                );

                switch (result) {
                  case (#ok(metricId)) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("metricId", int(metricId)),
                        ("action", str("metric_created")),
                        ("message", str("Metric '" # name # "' created successfully with ID " # Nat.toText(metricId))),
                      ]),
                      null,
                    );
                  };
                  case (#err(msg)) {
                    return buildErrorResponse(msg);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: name, description, unit, retentionDays");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract metricId (required)
            let metricIdOpt = switch (Json.get(json, "metricId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            switch (metricIdOpt) {
              case (?metricId) {
                // Extract optional fields
                let name = switch (Json.get(json, "name")) {
                  case (?#string(s)) { ?s };
                  case (_) { null };
                };
                let description = switch (Json.get(json, "description")) {
                  case (?#string(s)) { ?s };
                  case (_) { null };
                };
                let unit = switch (Json.get(json, "unit")) {
                  case (?#string(s)) { ?s };
                  case (_) { null };
                };
                let retentionDays = switch (Json.get(json, "retentionDays")) {
                  case (?#number(#int n)) {
                    if (n >= 0) { ?Int.abs(n) } else { null };
                  };
                  case _ { null };
                };

                let result = MetricModel.updateMetric(
                  registryState,
                  metricId,
                  name,
                  description,
                  unit,
                  retentionDays,
                );

                switch (result) {
                  case (#ok(())) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("metricId", int(metricId)),
                        ("action", str("metric_updated")),
                        ("message", str("Metric " # Nat.toText(metricId) # " updated successfully")),
                      ]),
                      null,
                    );
                  };
                  case (#err(msg)) {
                    return buildErrorResponse(msg);
                  };
                };
              };
              case (null) {
                return buildErrorResponse("Missing required field: metricId");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract metricId (required)
            let metricIdOpt = switch (Json.get(json, "metricId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            switch (metricIdOpt) {
              case (?metricId) {
                // Verify metric exists
                switch (MetricModel.getMetric(registryState, metricId)) {
                  case (null) {
                    return buildErrorResponse("Metric not found");
                  };
                  case (?metric) {
                    // Parse optional since timestamp (ISO string -> nanoseconds)
                    let sinceNanos = switch (Json.get(json, "since")) {
                      case (?#string(_isoString)) {
                        // For now, accept the timestamp as-is
                        // TODO: implement proper ISO string parsing
                        null;
                      };
                      case (_) { null };
                    };

                    // Get datapoints
                    let allDatapoints = MetricModel.getDatapoints(
                      datapoints,
                      metricId,
                      sinceNanos,
                    );

                    // Apply limit if specified
                    let limitOpt = switch (Json.get(json, "limit")) {
                      case (?#number(#int n)) {
                        if (n >= 0) { ?Int.abs(n) } else { null };
                      };
                      case _ { null };
                    };

                    let limitedDatapoints = switch (limitOpt) {
                      case (?limit) {
                        if (allDatapoints.size() <= limit) {
                          allDatapoints;
                        } else {
                          // Take first N (already sorted newest first)
                          Array.tabulate<MetricModel.MetricDatapoint>(
                            limit,
                            func(i : Nat) : MetricModel.MetricDatapoint {
                              allDatapoints[i];
                            },
                          );
                        };
                      };
                      case (null) { allDatapoints };
                    };

                    // Format datapoints as JSON
                    let datapointsJson = arr(
                      Array.map<MetricModel.MetricDatapoint, Json.Json>(
                        limitedDatapoints,
                        func(dp : MetricModel.MetricDatapoint) : Json.Json {
                          let sourceText = switch (dp.source) {
                            case (#manual(s)) { "manual: " # s };
                            case (#integration(s)) { "integration: " # s };
                            case (#evaluator(s)) { "evaluator: " # s };
                            case (#other(s)) { "other: " # s };
                          };
                          obj([
                            ("timestamp", int(dp.timestamp)),
                            ("value", #number(#float(dp.value))),
                            ("source", str(sourceText)),
                          ]);
                        },
                      )
                    );

                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("metricId", int(metricId)),
                        ("metricName", str(metric.name)),
                        ("unit", str(metric.unit)),
                        ("count", int(limitedDatapoints.size())),
                        ("datapoints", datapointsJson),
                      ]),
                      null,
                    );
                  };
                };
              };
              case (null) {
                return buildErrorResponse("Missing required field: metricId");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract required fields
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let nameOpt = switch (Json.get(json, "name")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };
            let descriptionOpt = switch (Json.get(json, "description")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };
            let objectiveTypeOpt = switch (Json.get(json, "objectiveType")) {
              case (?#string("target")) { ?#target };
              case (?#string("contributing")) { ?#contributing };
              case (?#string("prerequisite")) { ?#prerequisite };
              case (?#string("guardrail")) { ?#guardrail };
              case _ { null };
            };
            let metricIdsOpt = switch (Json.get(json, "metricIds")) {
              case (?#array(items)) {
                ?extractNatArray(items);
              };
              case _ { null };
            };
            let computationOpt = switch (Json.get(json, "computation")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };
            let targetTypeOpt = switch (Json.get(json, "targetType")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };
            let targetDateOpt = switch (Json.get(json, "targetDate")) {
              case (?#number(#int n)) { ?n };
              case _ { null };
            };

            // Validate required fields
            switch (valueStreamIdOpt, nameOpt, objectiveTypeOpt, metricIdsOpt, computationOpt, targetTypeOpt) {
              case (?valueStreamId, ?name, ?objectiveType, ?metricIds, ?computation, ?targetType) {
                // Build target based on targetType
                let targetOpt : ?ObjectiveModel.ObjectiveTarget = switch (targetType) {
                  case ("percentage") {
                    switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?#percentage({ target = f }) };
                      case (?#number(#int i)) {
                        ?#percentage({ target = Float.fromInt(i) });
                      };
                      case _ { null };
                    };
                  };
                  case ("count") {
                    let targetValueOpt = switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    let directionOpt = switch (Json.get(json, "targetDirection")) {
                      case (?#string("increase")) { ?#increase };
                      case (?#string("decrease")) { ?#decrease };
                      case _ { null };
                    };
                    switch (targetValueOpt, directionOpt) {
                      case (?target, ?direction) {
                        ?#count({ target; direction });
                      };
                      case _ { null };
                    };
                  };
                  case ("threshold") {
                    let minOpt = switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    let maxOpt = switch (Json.get(json, "targetMax")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    ?#threshold({ min = minOpt; max = maxOpt });
                  };
                  case ("boolean") {
                    switch (Json.get(json, "targetBoolean")) {
                      case (?#bool(b)) { ?#boolean(b) };
                      case _ { null };
                    };
                  };
                  case _ { null };
                };

                switch (targetOpt) {
                  case (?target) {
                    let input : ObjectiveModel.ObjectiveInput = {
                      name;
                      description = descriptionOpt;
                      objectiveType;
                      metricIds;
                      computation;
                      target;
                      targetDate = targetDateOpt;
                    };

                    // Wrap workspace map into full objectives map
                    let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(workspaceId, workspaceObjectivesMap)], Nat.compare);

                    // Initialize value stream objectives if not exists
                    ObjectiveModel.initValueStreamObjectives(fullObjectivesMap, workspaceId, valueStreamId);

                    let result = ObjectiveModel.addObjective(
                      fullObjectivesMap,
                      workspaceId,
                      valueStreamId,
                      input,
                    );

                    switch (result) {
                      case (#ok(objectiveId)) {
                        return Json.stringify(
                          obj([
                            ("success", bool(true)),
                            ("objectiveId", int(objectiveId)),
                            ("message", str("Objective created successfully")),
                          ]),
                          null,
                        );
                      };
                      case (#err(error)) {
                        return buildErrorResponse(error);
                      };
                    };
                  };
                  case (null) {
                    return buildErrorResponse("Invalid target configuration for targetType: " # targetType);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: valueStreamId, name, objectiveType, metricIds, computation, and targetType are required");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            // Extract required IDs
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let objectiveIdOpt = switch (Json.get(json, "objectiveId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            switch (valueStreamIdOpt, objectiveIdOpt) {
              case (?valueStreamId, ?objectiveId) {
                // Extract optional update fields
                let nameOpt = switch (Json.get(json, "name")) {
                  case (?#string(s)) { ?s };
                  case _ { null };
                };

                let descriptionOpt : ??Text = switch (Json.get(json, "clearDescription")) {
                  case (?#bool(true)) { ?null };
                  case _ {
                    switch (Json.get(json, "description")) {
                      case (?#string(s)) { ?(?s) };
                      case _ { null };
                    };
                  };
                };

                let objectiveTypeOpt = switch (Json.get(json, "objectiveType")) {
                  case (?#string("target")) { ?#target };
                  case (?#string("contributing")) { ?#contributing };
                  case (?#string("prerequisite")) { ?#prerequisite };
                  case (?#string("guardrail")) { ?#guardrail };
                  case _ { null };
                };

                let metricIdsOpt = switch (Json.get(json, "metricIds")) {
                  case (?#array(items)) {
                    ?extractNatArray(items);
                  };
                  case _ { null };
                };

                let computationOpt = switch (Json.get(json, "computation")) {
                  case (?#string(s)) { ?s };
                  case _ { null };
                };

                // Handle target updates
                let targetOpt : ?ObjectiveModel.ObjectiveTarget = switch (Json.get(json, "targetType")) {
                  case (?#string("percentage")) {
                    switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?#percentage({ target = f }) };
                      case (?#number(#int i)) {
                        ?#percentage({ target = Float.fromInt(i) });
                      };
                      case _ { null };
                    };
                  };
                  case (?#string("count")) {
                    let targetValueOpt = switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    let directionOpt = switch (Json.get(json, "targetDirection")) {
                      case (?#string("increase")) { ?#increase };
                      case (?#string("decrease")) { ?#decrease };
                      case _ { null };
                    };
                    switch (targetValueOpt, directionOpt) {
                      case (?target, ?direction) {
                        ?#count({ target; direction });
                      };
                      case _ { null };
                    };
                  };
                  case (?#string("threshold")) {
                    let minOpt = switch (Json.get(json, "targetValue")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    let maxOpt = switch (Json.get(json, "targetMax")) {
                      case (?#number(#float f)) { ?f };
                      case (?#number(#int i)) { ?Float.fromInt(i) };
                      case _ { null };
                    };
                    ?#threshold({ min = minOpt; max = maxOpt });
                  };
                  case (?#string("boolean")) {
                    switch (Json.get(json, "targetBoolean")) {
                      case (?#bool(b)) { ?#boolean(b) };
                      case _ { null };
                    };
                  };
                  case _ { null };
                };

                let targetDateOpt : ??Int = switch (Json.get(json, "clearTargetDate")) {
                  case (?#bool(true)) { ?null };
                  case _ {
                    switch (Json.get(json, "targetDate")) {
                      case (?#number(#int n)) { ?(?n) };
                      case _ { null };
                    };
                  };
                };

                let statusOpt = switch (Json.get(json, "status")) {
                  case (?#string("active")) { ?#active };
                  case (?#string("paused")) { ?#paused };
                  case (?#string("archived")) { ?#archived };
                  case _ { null };
                };

                // Wrap workspace map into full objectives map
                let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(workspaceId, workspaceObjectivesMap)], Nat.compare);

                let result = ObjectiveModel.updateObjective(
                  fullObjectivesMap,
                  workspaceId,
                  valueStreamId,
                  objectiveId,
                  nameOpt,
                  descriptionOpt,
                  objectiveTypeOpt,
                  metricIdsOpt,
                  computationOpt,
                  targetOpt,
                  targetDateOpt,
                  statusOpt,
                );

                switch (result) {
                  case (#ok(())) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("message", str("Objective updated successfully")),
                      ]),
                      null,
                    );
                  };
                  case (#err(error)) {
                    return buildErrorResponse(error);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: valueStreamId and objectiveId are required");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let objectiveIdOpt = switch (Json.get(json, "objectiveId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            switch (valueStreamIdOpt, objectiveIdOpt) {
              case (?valueStreamId, ?objectiveId) {
                // Wrap workspace map into full objectives map
                let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(workspaceId, workspaceObjectivesMap)], Nat.compare);

                let result = ObjectiveModel.archiveObjective(
                  fullObjectivesMap,
                  workspaceId,
                  valueStreamId,
                  objectiveId,
                );

                switch (result) {
                  case (#ok(())) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("message", str("Objective archived successfully")),
                      ]),
                      null,
                    );
                  };
                  case (#err(error)) {
                    return buildErrorResponse(error);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: valueStreamId and objectiveId are required");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let objectiveIdOpt = switch (Json.get(json, "objectiveId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let valueOpt = switch (Json.get(json, "value")) {
              case (?#number(#float f)) { ?f };
              case (?#number(#int i)) { ?Float.fromInt(i) };
              case _ { null };
            };

            switch (valueStreamIdOpt, objectiveIdOpt, valueOpt) {
              case (?valueStreamId, ?objectiveId, ?value) {
                let timestamp = switch (Json.get(json, "timestamp")) {
                  case (?#number(#int n)) { n };
                  case _ { Time.now() };
                };

                let valueWarning = switch (Json.get(json, "valueWarning")) {
                  case (?#string(s)) { ?s };
                  case _ { null };
                };

                // Build comment if provided
                let comments : [ObjectiveModel.ObjectiveDatapointComment] = switch (Json.get(json, "comment")) {
                  case (?#string(commentText)) {
                    let author = switch (Json.get(json, "commentAuthor")) {
                      case (?#string("user")) {
                        #principal(Principal.fromText("2vxsx-fae"));
                      }; // Placeholder
                      case (?#string(name)) { #assistant(name) };
                      case _ { #assistant("assistant") };
                    };
                    [{
                      timestamp = Time.now();
                      author;
                      message = commentText;
                    }];
                  };
                  case _ { [] };
                };

                let datapoint : ObjectiveModel.ObjectiveDatapoint = {
                  timestamp;
                  value = ?value;
                  valueWarning;
                  comments;
                };

                // Wrap workspace map into full objectives map
                let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(workspaceId, workspaceObjectivesMap)], Nat.compare);

                let result = ObjectiveModel.recordObjectiveDatapoint(
                  fullObjectivesMap,
                  workspaceId,
                  valueStreamId,
                  objectiveId,
                  datapoint,
                );

                switch (result) {
                  case (#ok(())) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("message", str("Datapoint recorded successfully")),
                        ("value", #number(#float(value))),
                      ]),
                      null,
                    );
                  };
                  case (#err(error)) {
                    return buildErrorResponse(error);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: valueStreamId, objectiveId, and value are required");
              };
            };
          };
        };
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
        switch (Json.parse(args)) {
          case (#err(error)) {
            return buildErrorResponse("Failed to parse arguments: " # debug_show error);
          };
          case (#ok(json)) {
            let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let objectiveIdOpt = switch (Json.get(json, "objectiveId")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };
            let perceivedImpactOpt = switch (Json.get(json, "perceivedImpact")) {
              case (?#string("negative")) { ?#negative };
              case (?#string("none")) { ?#none };
              case (?#string("low")) { ?#low };
              case (?#string("medium")) { ?#medium };
              case (?#string("high")) { ?#high };
              case (?#string("unclear")) { ?#unclear };
              case _ { null };
            };

            switch (valueStreamIdOpt, objectiveIdOpt, perceivedImpactOpt) {
              case (?valueStreamId, ?objectiveId, ?perceivedImpact) {
                let comment = switch (Json.get(json, "comment")) {
                  case (?#string(s)) { ?s };
                  case _ { null };
                };

                let author = switch (Json.get(json, "author")) {
                  case (?#string(name)) { #assistant(name) };
                  case _ { #assistant("assistant") };
                };

                let review : ObjectiveModel.ImpactReview = {
                  timestamp = Time.now();
                  author;
                  perceivedImpact;
                  comment;
                };

                // Wrap workspace map into full objectives map
                let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(workspaceId, workspaceObjectivesMap)], Nat.compare);

                let result = ObjectiveModel.addImpactReview(
                  fullObjectivesMap,
                  workspaceId,
                  valueStreamId,
                  objectiveId,
                  review,
                );

                switch (result) {
                  case (#ok(())) {
                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("message", str("Impact review added successfully")),
                      ]),
                      null,
                    );
                  };
                  case (#err(error)) {
                    return buildErrorResponse(error);
                  };
                };
              };
              case _ {
                return buildErrorResponse("Missing required fields: valueStreamId, objectiveId, and perceivedImpact are required");
              };
            };
          };
        };
      };
    };
  };
};
