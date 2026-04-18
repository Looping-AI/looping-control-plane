import List "mo:core/List";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Json "mo:json";
import { str } "mo:json";
import ToolTypes "./tool-types";
import ToolRegistry "./tool-registry";
import LlmWrapper "./llm-wrapper";
import CoreApi "./core-api";
import ExecutionTypes "../control-plane-core/types/execution";

module {

  // ── CallCore builder ───────────────────────────────────────────────

  /// Build a CallCore function that injects the token nonce into every
  /// request body before forwarding to Core's execution API.
  public func buildCallCore(
    core : CoreApi.CoreApi,
    tokenNonce : Text,
  ) : ToolTypes.CallCore {
    func(
      method : ExecutionTypes.HttpMethod,
      path : Text,
      body : Text,
    ) : async { #ok : Text; #err : Text } {
      let enrichedBody = injectNonce(body, tokenNonce);
      await core.executionApi(method, path, enrichedBody);
    };
  };

  // ── Execute ────────────────────────────────────────────────────────

  /// Execute all tool calls returned by the LLM.
  /// Returns results in the same order as the input calls.
  public func execute(
    callCore : ToolTypes.CallCore,
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
            let output = await tool.handler(callCore, call.arguments);
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

  // ── Nonce injection ────────────────────────────────────────────────

  /// Inject the tokenNonce field into a JSON body string.
  public func injectNonce(body : Text, nonce : Text) : Text {
    switch (Json.parse(body)) {
      case (#ok(#object_(entries))) {
        let fields = List.empty<(Text, Json.Json)>();
        List.add(fields, ("tokenNonce", #string(nonce)));
        for ((k, v) in entries.vals()) {
          List.add(fields, (k, v));
        };
        Json.stringify(#object_(List.toArray(fields)), null);
      };
      case (_) {
        // Body is not a valid JSON object — wrap nonce-only
        Json.stringify(#object_([("tokenNonce", str(nonce))]), null);
      };
    };
  };
};
