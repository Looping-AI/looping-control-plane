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
    workflowId : Text,
    scopeGrants : [ExecutionTypes.ScopeGrant],
    toolCalls : [LlmWrapper.ToolCall],
  ) : async [ToolTypes.ToolResult] {
    let results = List.empty<ToolTypes.ToolResult>();

    for (call in toolCalls.vals()) {
      let startNs = Time.now();

      let outcome : ToolTypes.ToolCallOutcome = switch (
        ToolRegistry.get(workflowId, scopeGrants, call.toolName)
      ) {
        case (?tool) {
          try {
            let output = await tool.handler(wrapper, call.arguments);
            #success(output);
          } catch (e : Error) {
            #error("Handler error: " # Error.message(e));
          };
        };
        case (null) {
          #error("Unknown tool: " # call.toolName);
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
        case (#success(data)) { (data, true) };
        case (#error(err)) { ("Error: " # err, false) };
      };
      List.add(items, { callId = r.callId; output; success });
    };
    List.toArray(items);
  };

};
