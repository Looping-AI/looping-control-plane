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

  // ── Workflow constraints ──────────────────────────────────────────

  public type WorkflowConstraints = {
    maxRounds : Nat;
    maxTokenBudget : ?Nat;
  };

  // ── Secrets ────────────────────────────────────────────────────────

  public type WorkflowSecrets = {
    apiKeys : [(Text, Text)];
  };

  // ── Workflow Envelope ──────────────────────────────────────────────

  public type EnvelopePayload = {
    envelopeId : Nat;
    /// The engine version this envelope was dispatched with.
    /// null = not yet dispatched (set by the handler; overridden by the dispatch lambda before send).
    /// After a successful dispatch the lambda stamps the accepted version for audit trail.
    /// Format: "v1", "v1.1" — major.minor, no patch.
    dispatchedVersion : ?Text;
    /// The catalog hash Core received from the engine's listWorkflows() response.
    /// Must be included on every execute() call. The engine rejects calls where the
    /// hash is missing or does not match its current catalog.
    catalogHash : ?Text;
    requestId : Text;
    agentId : Nat;
    agentName : Text;
    workspaceId : Nat;
    workflowName : Text;
    /// The raw JSON arguments string the Core LLM supplied when it called this
    /// workflow tool. Forwarded verbatim so the engine's LLM knows exactly what
    /// the orchestrator requested (e.g. {"workspaceId":42,"format":"detailed"}).
    /// null when the Core LLM provided no arguments or an empty object.
    workflowArguments : ?Text;
    model : Text;
    messages : [ChatMessage];
    instructions : Text;
    constraints : WorkflowConstraints;
    secrets : WorkflowSecrets;
    scopeGrants : [ScopeGrant];
    envelopeNonce : Text;
  };

  // ── Workflow Stats ─────────────────────────────────────────────────

  public type WorkflowStats = {
    durationNs : ?Int;
    llmCalls : ?Nat;
    toolCalls : ?Nat;
    inputTokens : ?Nat;
    outputTokens : ?Nat;
    model : ?Text;
    rounds : ?Nat;
    estimatedDollarCost : ?Float;
  };

  // ── Workflow Status ────────────────────────────────────────────────

  public type WorkflowStatus = {
    #completed;
    #failed : Text;
    #roundLimitReached;
  };

  // ── Workflow Result (engine → Core return value) ────────────────────

  public type WorkflowResult = {
    status : WorkflowStatus;
    stats : WorkflowStats;
  };

  // ── Summarized Step (lightweight per-step detail for events) ───────

  public type SummarizedStep = {
    tool : Text;
    summary : Text;
    success : Bool;
  };

  // ── Workflow Events (engine → Core via workflow API) ────────────────

  public type WorkflowEvent = {
    #workflowMilestone : {
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
    };
    #workflowComplete : {
      humanSummary : Text;
      stepsDetail : [SummarizedStep];
      status : WorkflowStatus;
      stats : WorkflowStats;
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
      status : WorkflowStatus;
      stats : WorkflowStats;
    };
  };

  public type HandleResult = {
    response : { #ok : Text; #err : Text };
    asyncEffects : [AsyncEffect];
  };

};
