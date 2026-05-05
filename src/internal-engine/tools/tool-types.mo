import CoreWrapper "../wrappers/core-wrapper";

module {

  // ── Tool handler type ──────────────────────────────────────────────

  /// Handler function: receives a CoreWrapper + JSON arguments → returns structured outcome.
  public type ToolHandler = (CoreWrapper.CoreWrapper, Text) -> async ToolCallOutcome;

  // ── Tool call outcome types ────────────────────────────────────────

  /// Outcome of a single tool call
  public type ToolCallOutcome = {
    #ok : Text; // JSON result string
    #err : Text; // Structured JSON error: {"type":"camelCase","message":"..."}
  };

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
    durationMs : Nat;
  };
};
