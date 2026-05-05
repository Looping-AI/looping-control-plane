import Json "mo:json";
import { str; obj } "mo:json";
import List "mo:core/List";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Time "mo:core/Time";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";
import FunctionToolRegistry "./function-tool-registry";

module {
  // ============================================
  // Tool Executor
  // ============================================
  //
  // Executes tool calls returned by the LLM.
  //
  // ============================================

  /// Execute all tool calls from an LLM response
  /// Returns results for each call in the same order.
  /// Stops executing after the first suspension signal (dispatched or approvalRequired).
  /// Remaining calls receive a synthetic "notRun" result so the LLM understands they were skipped.
  public func execute(
    resources : ToolTypes.ToolResources,
    toolCalls : [OpenRouterWrapper.ToolCall],
  ) : async [ToolTypes.ToolResult] {
    let results = List.empty<ToolTypes.ToolResult>();
    var suspended = false;

    label exec_ for (call in toolCalls.vals()) {
      if (suspended) {
        List.add(
          results,
          {
            callId = call.callId;
            result = #ok("{\"notRun\":true,\"reason\":\"A prior call in this batch triggered a suspension point. This call was not executed.\"}");
            durationMs = 0;
          },
        );
        continue exec_;
      };
      let result = await executeOne(resources, call);
      List.add(results, result);
      if (isSuspensionResult(result)) {
        suspended := true;
      };
    };

    List.toArray(results);
  };

  /// Execute a single tool call
  private func executeOne(
    resources : ToolTypes.ToolResources,
    call : OpenRouterWrapper.ToolCall,
  ) : async ToolTypes.ToolResult {
    let startNs = Time.now();
    // First, check function tools (static registry)
    let outcome : ToolTypes.ToolCallOutcome = switch (FunctionToolRegistry.get(resources, call.toolName)) {
      case (?tool) {
        try {
          await tool.handler(call.arguments);
        } catch (e : Error) {
          #err(Json.stringify(obj([("type", str("handlerError")), ("message", str("Handler error: " # Error.message(e)))]), null));
        };
      };
      case (null) {
        // Unknown tool
        #err(Json.stringify(obj([("type", str("unknownTool")), ("message", str("Unknown tool: " # call.toolName))]), null));
      };
    };
    let durationMs : Nat = Int.abs(Time.now() - startNs) / 1_000_000;
    { callId = call.callId; result = outcome; durationMs };
  };

  /// Returns true if a tool result carries a suspension signal (dispatched or approvalRequired).
  /// Used to stop the execute loop early so subsequent calls are not run.
  private func isSuspensionResult(result : ToolTypes.ToolResult) : Bool {
    switch (result.result) {
      case (#ok(output)) {
        switch (Json.parse(output)) {
          case (#ok(json)) {
            switch (Json.get(json, "dispatched"), Json.get(json, "approvalRequired")) {
              case (?#bool(true), _) { true };
              case (_, ?#bool(true)) { true };
              case _ { false };
            };
          };
          case _ { false };
        };
      };
      case (#err(_)) { false };
    };
  };

  /// Format tool results as input for the next LLM turn
  /// Uses a structured format the LLM can understand
  public func formatResultsForLlm(results : [ToolTypes.ToolResult]) : Text {
    var output = "";
    for (result in results.vals()) {
      output #= "Tool call " # result.callId # " result:\n";
      switch (result.result) {
        case (#ok(data)) {
          output #= data # "\n\n";
        };
        case (#err(err)) {
          let message = switch (Json.parse(err)) {
            case (#ok(parsed)) {
              switch (Json.get(parsed, "message")) {
                case (?#string(msg)) { msg };
                case (_) { err };
              };
            };
            case (#err(_)) { err };
          };
          output #= message # "\n\n";
        };
      };
    };
    output;
  };
};
