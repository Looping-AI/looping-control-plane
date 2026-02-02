import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Json "mo:json";
import { str; obj; int } "mo:json";
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
    // VALUE STREAM TOOLS - require workspaceId + valueStreams with write access
    // ==========================================
    switch (resources.workspaceId, resources.valueStreams) {
      case (?wsId, ?vs) {
        if (vs.write) {
          List.add(tools, saveValueStreamTool(wsId, vs.map));
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
};
