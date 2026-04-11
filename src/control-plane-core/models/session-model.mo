/// Session Model
///
/// Manages the three-level Agent Session hierarchy:
///   AgentSession → Turns → Trace Entries
///
/// One persistent session per agent (keyed by agentId).
/// Append-only turns per session, immutable trace entries per turn.
/// Delegation lineage via turn-level `triggerTurnId`.
///
/// See docs/plans/agent-session-schema.md for the full target schema.

import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Constants "../constants";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";

module {

  // ============================================
  // Types
  // ============================================

  public type CompactionState = {
    hotSummary : Text;
    lastCompactedTurnId : ?Text;
    warmSummary : ?Text;
    coldSummary : ?Text;
    lastWorkerRunAtNs : ?Int;
  };

  public type SessionPolicy = {
    summaryTokenBudget : Nat;
    maxTruncatedTokens : Nat;
  };

  public type AgentSessionRecord = {
    agentId : Nat;
    var nextTurnNumber : Nat;
    compaction : CompactionState;
    var policy : SessionPolicy;
  };

  public type TurnStatus = {
    #running;
    #succeeded;
    #failed;
  };

  public type SourceRef = {
    #slack : { channelId : Text; ts : Text };
    #github : { runId : Text; workflowId : Text };
    #timer : { timerLabel : Text };
  };

  public type TurnCost = {
    promptTokens : Nat;
    completionTokens : Nat;
    estimatedMicroUnits : Nat;
  };

  public type TraceDetail = {
    #contextAssembled : {
      summaryTokens : Nat;
      rawTurnsIncluded : Nat;
      channelSnippets : Nat;
    };
    #llmCall : {
      model : Text;
      durationMs : Nat;
      finishReason : Text;
      content : ?Text;
      truncatedContent : ?Text;
      thinking : ?Text;
      toolRequests : ?[{ name : Text; input : Text }];
      cost : TurnCost;
    };
    #toolCall : {
      name : Text;
      input : Text;
      output : Text;
      truncatedOutput : ?Text;
      success : Bool;
      durationMs : Nat;
    };
    #slackPost : { channelId : Text; threadTs : ?Text; ts : Text };
    #roundLimitHit;
    #policyRejection : { reason : Text };
    #faultRecovered : { error : Text };
  };

  public type AgentTurnRecord = {
    turnId : Text;
    agentId : Nat;
    startedAtNs : Int;
    var completedAtNs : ?Int;
    var status : TurnStatus;
    sourceRef : ?SourceRef;
    triggerTurnId : ?Text;
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;
    var cost : ?TurnCost;
    var errorSummary : ?Text;
  };

  public type TurnTraceEntry = {
    seq : Nat;
    atNs : Int;
    detail : TraceDetail;
  };

  // ============================================
  // Stores
  // ============================================

  public type SessionStores = {
    sessions : Map.Map<Nat, AgentSessionRecord>;
    turns : Map.Map<Nat, Map.Map<Nat, AgentTurnRecord>>;
    traces : Map.Map<Text, List.List<TurnTraceEntry>>;
  };

  public func emptyStores() : SessionStores {
    {
      sessions = Map.empty<Nat, AgentSessionRecord>();
      turns = Map.empty<Nat, Map.Map<Nat, AgentTurnRecord>>();
      traces = Map.empty<Text, List.List<TurnTraceEntry>>();
    };
  };

  // ============================================
  // Session CRUD
  // ============================================

  /// Get or lazily create an AgentSessionRecord for the given agent.
  public func getOrCreateSession(stores : SessionStores, agentId : Nat) : AgentSessionRecord {
    switch (Map.get(stores.sessions, Nat.compare, agentId)) {
      case (?session) { session };
      case (null) {
        let session : AgentSessionRecord = {
          agentId;
          var nextTurnNumber = 0;
          compaction = {
            hotSummary = "";
            lastCompactedTurnId = null;
            warmSummary = null;
            coldSummary = null;
            lastWorkerRunAtNs = null;
          };
          var policy = {
            summaryTokenBudget = Constants.DEFAULT_SUMMARY_TOKEN_BUDGET;
            maxTruncatedTokens = Constants.DEFAULT_MAX_TRUNCATED_TOKENS;
          };
        };
        Map.add(stores.sessions, Nat.compare, agentId, session);
        session;
      };
    };
  };

  /// Update the session policy for an existing agent session.
  /// Returns true if the session existed and was updated, false otherwise.
  public func updateSessionPolicy(stores : SessionStores, agentId : Nat, newPolicy : SessionPolicy) : Bool {
    switch (Map.get(stores.sessions, Nat.compare, agentId)) {
      case (?session) {
        session.policy := newPolicy;
        true;
      };
      case (null) { false };
    };
  };

  // ============================================
  // Turn CRUD
  // ============================================

  /// Create a new turn for the given agent.
  /// Advances `nextTurnNumber` atomically and appends to the agent's turn list.
  public func createTurn(
    stores : SessionStores,
    agentId : Nat,
    sourceRef : ?SourceRef,
    triggerTurnId : ?Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
  ) : AgentTurnRecord {
    let session = getOrCreateSession(stores, agentId);
    let turnNumber = session.nextTurnNumber;
    session.nextTurnNumber += 1;

    let turnId = Nat.toText(agentId) # "_" # Nat.toText(turnNumber);
    let turn : AgentTurnRecord = {
      turnId;
      agentId;
      startedAtNs = Time.now();
      var completedAtNs = null;
      var status : TurnStatus = #running;
      sourceRef;
      triggerTurnId;
      userAuthContext;
      var cost = null;
      var errorSummary = null;
    };

    let turnMap = switch (Map.get(stores.turns, Nat.compare, agentId)) {
      case (?m) { m };
      case (null) {
        let m = Map.empty<Nat, AgentTurnRecord>();
        Map.add(stores.turns, Nat.compare, agentId, m);
        m;
      };
    };
    Map.add(turnMap, Nat.compare, turnNumber, turn);
    turn;
  };

  /// Finalize a turn with terminal status, cost, and optional error summary.
  /// The status must be terminal (#succeeded or #failed), never #running.
  /// Traps if status is #running (developer error).
  public func completeTurn(
    stores : SessionStores,
    turnId : Text,
    status : TurnStatus,
    cost : ?TurnCost,
    errorSummary : ?Text,
  ) : () {
    assert status != #running;
    switch (findTurn(stores, turnId)) {
      case (null) {};
      case (?turn) {
        turn.status := status;
        turn.completedAtNs := ?Time.now();
        turn.cost := cost;
        turn.errorSummary := errorSummary;
      };
    };
  };

  /// Find a turn by its turnId. O(log n) via nested Map lookup.
  /// turnId format is "{agentId}_{turnNumber}".
  public func findTurn(stores : SessionStores, turnId : Text) : ?AgentTurnRecord {
    let (agentId, turnNumber) = switch (parseTurnIdComponents(turnId)) {
      case (null) { return null };
      case (?ids) { ids };
    };
    switch (Map.get(stores.turns, Nat.compare, agentId)) {
      case (null) { null };
      case (?turnMap) { Map.get(turnMap, Nat.compare, turnNumber) };
    };
  };

  /// Get all turns for an agent.
  public func getTurnsByAgent(stores : SessionStores, agentId : Nat) : ?Map.Map<Nat, AgentTurnRecord> {
    Map.get(stores.turns, Nat.compare, agentId);
  };

  // ============================================
  // Trace CRUD
  // ============================================

  /// Append a trace entry with auto-incremented seq.
  public func appendTrace(stores : SessionStores, turnId : Text, detail : TraceDetail) : () {
    let traceList = switch (Map.get(stores.traces, Text.compare, turnId)) {
      case (?list) { list };
      case (null) {
        let list = List.empty<TurnTraceEntry>();
        Map.add(stores.traces, Text.compare, turnId, list);
        list;
      };
    };
    let seq = List.size(traceList) + 1;
    List.add(
      traceList,
      {
        seq;
        atNs = Time.now();
        detail;
      },
    );
  };

  /// Get all traces for a turn.
  public func getTraces(stores : SessionStores, turnId : Text) : ?List.List<TurnTraceEntry> {
    Map.get(stores.traces, Text.compare, turnId);
  };

  // ============================================
  // Cleanup
  // ============================================

  /// Hard-delete turns (and their traces) with startedAtNs older than cutoffNs.
  /// Uses startedAtNs (never null) rather than completedAtNs, so orphaned
  /// #running turns that never reached a terminal state are also collected.
  /// Pops from minEntry() of each agent's inner Map (ordered by turnNumber,
  /// which is monotonically increasing) until a turn newer than the cutoff is
  /// reached — O(deleted × log n) rather than O(total turns).
  /// Returns the number of turns deleted.
  public func deleteTurnsOlderThan(stores : SessionStores, cutoffNs : Int) : Nat {
    var deleted : Nat = 0;
    for ((_, turnMap) in Map.entries(stores.turns)) {
      // Collect keys to delete, then remove after scanning
      let toRemove = List.empty<(Nat, Text)>();
      label l loop {
        switch (Map.minEntry(turnMap)) {
          case (null) { break l };
          case (?(turnNumber, turn)) {
            if (turn.startedAtNs < cutoffNs) {
              List.add(toRemove, (turnNumber, turn.turnId));
              // Remove from turnMap immediately so minEntry advances;
              // this is safe because minEntry is a standalone query, not an iterator.
              Map.remove(turnMap, Nat.compare, turnNumber);
            } else {
              break l;
            };
          };
        };
      };
      for ((_, turnId) in List.values(toRemove)) {
        Map.remove(stores.traces, Text.compare, turnId);
        deleted += 1;
      };
    };
    deleted;
  };

  // ============================================
  // Helpers
  // ============================================

  /// Count the delegation chain depth by walking triggerTurnId.
  /// Bounded by MAX_AGENT_ROUNDS to prevent infinite loops.
  public func countDelegationDepth(stores : SessionStores, triggerTurnId : ?Text, maxDepth : Nat) : Nat {
    var depth : Nat = 0;
    var current = triggerTurnId;
    loop {
      switch (current) {
        case (null) { return depth };
        case (?tid) {
          depth += 1;
          if (depth >= maxDepth) { return depth };
          switch (findTurn(stores, tid)) {
            case (?turn) { current := turn.triggerTurnId };
            case (null) { return depth };
          };
        };
      };
    };
  };

  /// Aggregate cost from all #llmCall trace entries in a turn.
  public func aggregateTurnCost(stores : SessionStores, turnId : Text) : ?TurnCost {
    switch (Map.get(stores.traces, Text.compare, turnId)) {
      case (null) { null };
      case (?traceList) {
        var promptTokens : Nat = 0;
        var completionTokens : Nat = 0;
        var estimatedMicroUnits : Nat = 0;
        var hasLlmCalls = false;
        for (entry in List.values(traceList)) {
          switch (entry.detail) {
            case (#llmCall({ cost })) {
              promptTokens += cost.promptTokens;
              completionTokens += cost.completionTokens;
              estimatedMicroUnits += cost.estimatedMicroUnits;
              hasLlmCalls := true;
            };
            case _ {};
          };
        };
        if (hasLlmCalls) {
          ?{ promptTokens; completionTokens; estimatedMicroUnits };
        } else {
          null;
        };
      };
    };
  };

  /// Parse agentId and turnNumber from turnId "{agentId}_{turnNumber}".
  func parseTurnIdComponents(turnId : Text) : ?(Nat, Nat) {
    let chars = turnId.chars();
    var left = "";
    label l loop {
      switch (chars.next()) {
        case (null) { break l };
        case (?c) {
          if (c == '_') { break l };
          left #= Text.fromChar(c);
        };
      };
    };
    var right = "";
    for (c in chars) { right #= Text.fromChar(c) };
    switch (Nat.fromText(left), Nat.fromText(right)) {
      case (?agentId, ?turnNumber) { ?(agentId, turnNumber) };
      case _ { null };
    };
  };
};
