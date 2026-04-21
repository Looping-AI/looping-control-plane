import ExecutionTypes "../execution-types";

module {

  // ── CallCore function type ─────────────────────────────────────────

  /// A function that calls Core's execution API.
  /// Parameters: (method, path, body) where body is JSON without envelopeNonce.
  /// The implementation injects envelopeNonce automatically before forwarding.
  public type CallCore = (ExecutionTypes.HttpMethod, Text, Text) -> async {
    #ok : Text;
    #err : Text;
  };

  // ── Tool handler type ──────────────────────────────────────────────

  /// Handler function: receives callCore + JSON arguments → returns JSON result.
  public type ToolHandler = (CallCore, Text) -> async Text;

  // ── Tool call outcome types ────────────────────────────────────────

  /// Outcome of a single tool call
  public type ToolCallOutcome = {
    #success : Text; // JSON result string
    #error : Text; // Error message
  };

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
    durationMs : Nat;
  };
};
