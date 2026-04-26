import CoreWrapper "../wrappers/core-wrapper";

module {

  // ── Tool handler type ──────────────────────────────────────────────

  /// Handler function: receives a CoreWrapper + JSON arguments → returns structured outcome.
  public type ToolHandler = (CoreWrapper.CoreWrapper, Text) -> async ToolCallOutcome;

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
