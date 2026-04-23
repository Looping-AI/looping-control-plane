/// Run Types
/// Types for tracking the lifecycle of execution runs inside the engine.

import ExecutionTypes "../execution-types";

module {

  // ── Run Step ─────────────────────────────────────────────────────
  // One discrete action within a run (e.g. an LLM call or a single tool invocation).
  // Finer-grained than SummarizedStep — includes timing and explicit ok/err result.

  public type RunStep = {
    action : Text; // e.g. "llm_call", "tool:slack_post_message"
    summary : Text; // human-readable summary (truncated output or error)
    result : { #ok; #err : Text };
    timestamp : Int; // Time.now() when the step completed
    durationNs : Int; // wall-clock duration of this step
  };

  // ── Run Record ───────────────────────────────────────────────────
  // Full lifecycle record for one execution run.

  public type RunRecord = {
    // Identity — from the envelope
    envelopeId : Nat;
    requestId : Text;
    agentName : Text;
    workflowId : Text;

    // The full envelope — needed by the runner to execute
    envelope : ExecutionTypes.EnvelopePayload;

    // Lifecycle timestamps
    enqueuedAt : Int;
    claimedAt : ?Int;
    completedAt : ?Int;
    failedAt : ?Int;
    failedError : Text;

    // Outcome (populated on completion)
    status : ?ExecutionTypes.ExecutionStatus;
    stats : ?ExecutionTypes.ExecutionStats;

    // Per-step detail (accumulated during execution)
    steps : [RunStep];
  };

};
