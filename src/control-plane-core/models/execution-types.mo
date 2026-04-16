import SessionModel "session-model";

module {

  // ── Chat message types (engine-agnostic) ───────────────────────────

  public type ChatRole = {
    #user;
    #assistant;
    #system_;
    #developer;
  };

  public type ChatMessage = {
    role : ChatRole;
    content : Text;
  };

  // ── Execution constraints ──────────────────────────────────────────

  public type ExecutionConstraints = {
    maxRounds : Nat;
    maxTokenBudget : ?Nat;
  };

  // ── Secrets ────────────────────────────────────────────────────────

  public type ExecutionSecrets = {
    apiKeys : [(Text, Text)];
  };

  // ── Execution Envelope ─────────────────────────────────────────────

  public type ExecutionEnvelope = {
    envelopeVersion : Nat;
    requestId : Text;
    agentId : Nat;
    agentName : Text;
    workspaceId : Nat;
    workflowId : Text;
    messages : [ChatMessage];
    instructions : Text;
    constraints : ExecutionConstraints;
    secrets : ExecutionSecrets;
  };

  // ── Trace (reuse session model types for zero-transform applicator) ─

  public type TraceDetail = SessionModel.TraceDetail;
  public type TraceEntry = SessionModel.TurnTraceEntry;

  // ── Execution Stats ────────────────────────────────────────────────

  public type ExecutionStats = {
    durationNs : Int;
    llmCalls : Nat;
    toolCalls : Nat;
    inputTokens : Nat;
    outputTokens : Nat;
    model : Text;
    rounds : Nat;
  };

  // ── Package Status ─────────────────────────────────────────────────

  public type PackageStatus = {
    #completed;
    #failed : Text;
    #roundLimitReached;
  };

  // ── Execution Package ──────────────────────────────────────────────

  public type ExecutionPackage = {
    packageVersion : Nat;
    requestId : Text;
    status : PackageStatus;
    response : ?Text;
    trace : [TraceEntry];
    stats : ExecutionStats;
    availableWorkflows : [Text];
  };

};
