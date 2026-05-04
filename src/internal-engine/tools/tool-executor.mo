import Json "mo:json";
import { str; obj } "mo:json";
import List "mo:core/List";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Time "mo:core/Time";
import ToolTypes "./tool-types";
import ToolRegistry "./tool-registry";
import LlmWrapper "../wrappers/llm-wrapper";
import CoreWrapper "../wrappers/core-wrapper";
import ExecutionTypes "../execution-types";

module {

  // ── Execute ────────────────────────────────────────────────────────

  /// Execute all tool calls returned by the LLM.
  /// Returns results in the same order as the input calls.
  public func execute(
    wrapper : CoreWrapper.CoreWrapper,
    workflowName : Text,
    scopeGrants : [ExecutionTypes.ScopeGrant],
    toolCalls : [LlmWrapper.ToolCall],
  ) : async [ToolTypes.ToolResult] {
    let results = List.empty<ToolTypes.ToolResult>();

    for (call in toolCalls.vals()) {
      let startNs = Time.now();

      let outcome : ToolTypes.ToolCallOutcome = switch (
        ToolRegistry.get(workflowName, scopeGrants, call.toolName)
      ) {
        case (?tool) {
          try {
            await tool.handler(wrapper, call.arguments);
          } catch (e : Error) {
            #err(Json.stringify(obj([("type", str("handlerError")), ("message", str("Handler error: " # Error.message(e)))]), null));
          };
        };
        case (null) {
          #err(Json.stringify(obj([("type", str("unknownTool")), ("message", str("Unknown tool: " # call.toolName))]), null));
        };
      };

      let durationMs : Nat = Int.abs(Time.now() - startNs) / 1_000_000;
      List.add(results, { callId = call.callId; result = outcome; durationMs });
    };

    List.toArray(results);
  };

  // ── Format for LLM ────────────────────────────────────────────────

  /// Format tool execution results for feeding back into the LLM.
  public func formatResultsForLlm(results : [ToolTypes.ToolResult]) : [{
    callId : Text;
    output : Text;
    success : Bool;
  }] {
    let items = List.empty<{ callId : Text; output : Text; success : Bool }>();
    for (r in results.vals()) {
      let (output, success) = switch (r.result) {
        case (#ok(data)) { (data, true) };
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
          (message, false);
        };
      };
      List.add(items, { callId = r.callId; output; success });
    };
    List.toArray(items);
  };

};
