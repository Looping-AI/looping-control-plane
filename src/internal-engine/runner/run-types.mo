/// Run Types
/// Types for tracking the lifecycle of workflow runs inside the engine.

import WorkflowTypes "../workflow-types";

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
  // Full lifecycle record for one workflow run.

  public type RunRecord = {
    // Identity — from the envelope
    envelopeId : Nat;
    requestId : Text;
    agentName : Text;
    workflowName : Text;

    // The full envelope — needed by the runner to execute
    envelope : WorkflowTypes.EnvelopePayload;

    // Lifecycle timestamps
    enqueuedAt : Int;
    claimedAt : ?Int;
    completedAt : ?Int;
    failedAt : ?Int;
    failedError : Text;

    // Outcome (populated on completion)
    status : ?WorkflowTypes.WorkflowStatus;
    stats : ?WorkflowTypes.WorkflowStats;

    // Per-step detail (accumulated during execution)
    steps : [RunStep];

    // Result of the final emitComplete call to Core.
    // null  = emit not yet attempted (transient — only between markFailed/markCompleted and setEmitResult)
    // #ok   = Core acknowledged the notification
    // #err  = emit failed; Text contains the error message
    coreEmitResult : ?{ #ok; #err : Text };
  };

  // ── Run Outcome ──────────────────────────────────────────────────
  // Returned by the runner after executing an envelope.
  // The caller is responsible for marking the store and emitting to Core.

  public type RunOutcome = {
    status : WorkflowTypes.WorkflowStatus;
    humanSummary : Text;
    steps : [RunStep];
    summarizedSteps : [WorkflowTypes.SummarizedStep];
    stats : WorkflowTypes.WorkflowStats;
  };

};
