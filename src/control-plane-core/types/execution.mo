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
    #workspace : { access : ScopeAccess };
    #agents : { access : ScopeAccess }; // collection-level agent access (list/create/update/delete)
    #agent : { id : Nat; access : ScopeAccess }; // per-agent self-read for non-admin agents
    #slackQueue : { access : ScopeAccess }; // Slack incoming-event queue management (org admin only)
    #session : { access : ScopeAccess };
  };

  // ── Chat message types (engine-agnostic) ──────────────────────────────────

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

  public type EnvelopePayload = {
    envelopeId : Nat;
    /// The engine version this envelope was dispatched with.
    /// null = not yet dispatched (set by the handler; overridden by the dispatch lambda before send).
    /// After a successful dispatch the lambda stamps the accepted version for audit trail.
    /// Format: "v1", "v1.1" — major.minor, no patch.
    dispatchedVersion : ?Text;
    requestId : Text;
    agentId : Nat;
    agentName : Text;
    workspaceId : Nat;
    workflowName : Text;
    model : Text;
    messages : [ChatMessage];
    instructions : Text;
    constraints : ExecutionConstraints;
    secrets : ExecutionSecrets;
    scopeGrants : [ScopeGrant];
    envelopeNonce : Text;
    /// The catalog hash Core received from the engine's listWorkflows() response.
    /// Must be included on every execute() call. The engine rejects calls where the
    /// hash is missing or does not match its current catalog.
    catalogHash : ?Text;
  };

  // ── Execution Stats ────────────────────────────────────────────────

  public type ExecutionStats = {
    durationNs : ?Int;
    llmCalls : ?Nat;
    toolCalls : ?Nat;
    inputTokens : ?Nat;
    outputTokens : ?Nat;
    model : ?Text;
    rounds : ?Nat;
    estimatedDollarCost : ?Float;
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
      envelopeId : Nat;
      turnId : Text;
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
    };
    #complete : {
      envelopeId : Nat;
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
