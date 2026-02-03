import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Json "mo:json";
import { str; obj; int; float; bool; arr } "mo:json";
import GroqWrapper "../wrappers/groq-wrapper";
import ToolTypes "./tool-types";
import ValueStreamModel "../models/value-stream-model";

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
};
