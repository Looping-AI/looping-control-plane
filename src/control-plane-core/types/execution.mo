module {

  // ── HTTP method (Candid-native, no string parsing) ─────────────────

  public type HttpMethod = {
    #get;
    #post;
    #delete;
  };

  // ── Scope types (authorization) ────────────────────────────────────

  public type ScopeAccess = {
    #read;
    #write; // write implies read
  };

  public type ScopeGrant = {
    #workspace : { id : ?Nat; access : ScopeAccess };
    #agent : { id : ?Nat; access : ScopeAccess };
  };

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
    envelopeId : Text;
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
    scopeGrants : [ScopeGrant];
    tokenNonce : Text;
  };

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

  // ── Execution Status ───────────────────────────────────────────────

  public type ExecutionStatus = {
    #completed;
    #failed : Text;
    #roundLimitReached;
  };

  // ── Execution Result (engine → Core return value) ──────────────────

  public type ExecutionResult = {
    status : ExecutionStatus;
    stats : ExecutionStats;
  };

  // ── Summarized Step (lightweight per-step detail for events) ───────

  public type SummarizedStep = {
    tool : Text;
    summary : Text;
    success : Bool;
  };

  // ── Execution Events (engine → Core via execution API) ─────────────

  public type ExecutionEvent = {
    #executionMilestone : {
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
    };
    #executionComplete : {
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
      status : ExecutionStatus;
      stats : ExecutionStats;
    };
  };

  // ── Async effects (returned by handleRequest for main.mo to schedule) ──

  public type AsyncEffect = {
    #milestone : {
      envelopeId : Text;
      turnId : Text;
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
    };
    #complete : {
      envelopeId : Text;
      turnId : Text;
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
      status : ExecutionStatus;
      stats : ExecutionStats;
    };
  };

  public type HandleResult = {
    response : { #ok : Text; #err : Text };
    asyncEffects : [AsyncEffect];
  };

};
