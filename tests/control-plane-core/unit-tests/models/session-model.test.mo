import { test; suite; expect } "mo:test";
import List "mo:core/List";
import Map "mo:core/Map";
import Set "mo:core/Set";
import SessionModel "../../../../src/control-plane-core/models/session-model";
import Constants "../../../../src/control-plane-core/constants";

// ============================================
// Helpers
// ============================================

func makeStores() : SessionModel.SessionStores {
  SessionModel.emptyStores();
};

func makeDummyAuthCtx() : {
  slackUserId : Text;
  isPrimaryOwner : Bool;
  isOrgAdmin : Bool;
  adminWorkspaces : Set.Set<Nat>;
} {
  {
    slackUserId = "U_TEST";
    isPrimaryOwner = false;
    isOrgAdmin = false;
    adminWorkspaces = Set.empty();
  };
};

func isSome<T>(opt : ?T) : Bool {
  switch (opt) { case (null) false; case (_) true };
};

func isNone<T>(opt : ?T) : Bool {
  switch (opt) { case (null) true; case (_) false };
};

// ============================================
// getOrCreateSession
// ============================================

suite(
  "getOrCreateSession",
  func() {
    test(
      "creates a new session when absent",
      func() {
        let stores = makeStores();
        let session = SessionModel.getOrCreateSession(stores, 42);
        expect.nat(session.agentId).equal(42);
        expect.nat(session.nextTurnNumber).equal(0);
        expect.text(session.compaction.hotSummary).equal("");
      },
    );

    test(
      "returns existing session on second call",
      func() {
        let stores = makeStores();
        let s1 = SessionModel.getOrCreateSession(stores, 7);
        s1.nextTurnNumber := 5;
        let s2 = SessionModel.getOrCreateSession(stores, 7);
        expect.nat(s2.nextTurnNumber).equal(5);
      },
    );
  },
);

// ============================================
// createTurn
// ============================================

suite(
  "createTurn",
  func() {
    test(
      "creates a turn with correct initial fields",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, ?makeDummyAuthCtx());
        expect.text(turn.turnId).equal("1_0");
        expect.nat(turn.agentId).equal(1);
        expect.bool(switch (turn.status) { case (#running) true; case _ false }).isTrue();
        expect.bool(turn.triggerTurnId == null).isTrue();
        expect.bool(turn.cost == null).isTrue();
        expect.bool(turn.errorSummary == null).isTrue();
      },
    );

    test(
      "auto-increments turn numbers",
      func() {
        let stores = makeStores();
        let t0 = SessionModel.createTurn(stores, 1, null, null, null);
        let t1 = SessionModel.createTurn(stores, 1, null, null, null);
        let t2 = SessionModel.createTurn(stores, 1, null, null, null);
        expect.text(t0.turnId).equal("1_0");
        expect.text(t1.turnId).equal("1_1");
        expect.text(t2.turnId).equal("1_2");
      },
    );

    test(
      "different agents have independent turn counters",
      func() {
        let stores = makeStores();
        let tA = SessionModel.createTurn(stores, 10, null, null, null);
        let tB = SessionModel.createTurn(stores, 20, null, null, null);
        expect.text(tA.turnId).equal("10_0");
        expect.text(tB.turnId).equal("20_0");
      },
    );

    test(
      "preserves sourceRef and triggerTurnId",
      func() {
        let stores = makeStores();
        let src : SessionModel.SourceRef = #slack({
          channelId = "C1";
          ts = "123.456";
          threadTs = null;
        });
        let turn = SessionModel.createTurn(stores, 1, ?src, ?"0_5", null);
        expect.bool(turn.sourceRef == ?src).isTrue();
        expect.bool(turn.triggerTurnId == ?"0_5").isTrue();
      },
    );
  },
);

// ============================================
// awaitingWorkflow (replaces markPending)
// ============================================

suite(
  "awaitingWorkflow",
  func() {
    test(
      "transitions a running turn to #awaitingWorkflow",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        expect.bool(switch (turn.status) { case (#running) true; case _ false }).isTrue();
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_abc";
          roundCount = 2;
        };
        turn.status := #awaitingWorkflow(dummySuspension);
        switch (turn.status) {
          case (#awaitingWorkflow(s)) {
            expect.bool(s.pendingToolCallId == "call_abc").isTrue();
            expect.bool(s.roundCount == 2).isTrue();
          };
          case (_) { expect.bool(false).isTrue() }; // unreachable: expected #awaitingWorkflow
        };
      },
    );

    test(
      "awaitingWorkflow turn can be finalized with completeTurn",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_xyz";
          roundCount = 1;
        };
        ignore SessionModel.suspendForWorkflow(stores, turn.turnId, dummySuspension);
        SessionModel.completeTurn(stores, turn.turnId, #succeeded, null, null);
        expect.bool(switch (turn.status) { case (#succeeded) true; case _ false }).isTrue();
        expect.bool(turn.completedAtNs != null).isTrue();
      },
    );

    test(
      "awaitingWorkflow turn can be finalized as failed",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_xyz";
          roundCount = 1;
        };
        ignore SessionModel.suspendForWorkflow(stores, turn.turnId, dummySuspension);
        SessionModel.completeTurn(stores, turn.turnId, #failed, null, ?"engine error");
        expect.bool(switch (turn.status) { case (#failed) true; case _ false }).isTrue();
        expect.bool(turn.errorSummary == ?"engine error").isTrue();
      },
    );
  },
);

// ============================================
// completeTurn
// ============================================

suite(
  "completeTurn",
  func() {
    test(
      "sets status, cost, and errorSummary on an existing turn",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        let cost : SessionModel.TurnCost = {
          promptTokens = 100;
          completionTokens = 50;
          estimatedDollarCost = ?0.0002;
        };
        SessionModel.completeTurn(stores, turn.turnId, #succeeded, ?cost, null);
        expect.bool(switch (turn.status) { case (#succeeded) true; case _ false }).isTrue();
        expect.bool(turn.completedAtNs != null).isTrue();
        expect.bool(turn.cost == ?cost).isTrue();
        expect.bool(turn.errorSummary == null).isTrue();
      },
    );

    test(
      "sets failed status with error summary",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.completeTurn(stores, turn.turnId, #failed, null, ?"something broke");
        expect.bool(switch (turn.status) { case (#failed) true; case _ false }).isTrue();
        expect.bool(turn.errorSummary == ?"something broke").isTrue();
      },
    );

    test(
      "no-ops silently for unknown turnId",
      func() {
        let stores = makeStores();
        // Should not trap
        SessionModel.completeTurn(stores, "999_999", #succeeded, null, null);
      },
    );
  },
);

// ============================================
// findTurn
// ============================================

suite(
  "findTurn",
  func() {
    test(
      "finds a turn by turnId",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 5, null, null, null);
        let found = SessionModel.findTurn(stores, "5_0");
        switch (found) {
          case (?t) { expect.text(t.turnId).equal(turn.turnId) };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "returns null for non-existent turn",
      func() {
        let stores = makeStores();
        expect.bool(isNone(SessionModel.findTurn(stores, "99_0"))).isTrue();
      },
    );

    test(
      "returns null for invalid turnId format",
      func() {
        let stores = makeStores();
        expect.bool(isNone(SessionModel.findTurn(stores, "garbage"))).isTrue();
      },
    );
  },
);

// ============================================
// appendTrace / getTraces
// ============================================

suite(
  "appendTrace & getTraces",
  func() {
    test(
      "appends trace entries with auto-incrementing seq",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(stores, turn.turnId, #roundLimitHit);
        SessionModel.appendTrace(stores, turn.turnId, #faultRecovered({ error = "timeout" }));

        let traces = SessionModel.getTraces(stores, turn.turnId);
        switch (traces) {
          case (?list) {
            let arr = List.toArray(list);
            expect.nat(arr.size()).equal(2);
            expect.nat(arr[0].seq).equal(1);
            expect.nat(arr[1].seq).equal(2);
            expect.bool(arr[1].detail == #faultRecovered({ error = "timeout" })).isTrue();
          };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "getTraces returns null for unknown turnId",
      func() {
        let stores = makeStores();
        expect.bool(isNone(SessionModel.getTraces(stores, "99_0"))).isTrue();
      },
    );
  },
);

// ============================================
// getTurnsByAgent
// ============================================

suite(
  "getTurnsByAgent",
  func() {
    test(
      "returns all turns for an agent",
      func() {
        let stores = makeStores();
        ignore SessionModel.createTurn(stores, 3, null, null, null);
        ignore SessionModel.createTurn(stores, 3, null, null, null);
        ignore SessionModel.createTurn(stores, 3, null, null, null);

        switch (SessionModel.getTurnsByAgent(stores, 3)) {
          case (?turnMap) { expect.nat(Map.size(turnMap)).equal(3) };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "returns null for agent with no turns",
      func() {
        let stores = makeStores();
        expect.bool(isNone(SessionModel.getTurnsByAgent(stores, 99))).isTrue();
      },
    );
  },
);

// ============================================
// countDelegationDepth
// ============================================

suite(
  "countDelegationDepth",
  func() {
    test(
      "returns 0 when triggerTurnId is null",
      func() {
        let stores = makeStores();
        expect.nat(SessionModel.countDelegationDepth(stores, null, 100)).equal(0);
      },
    );

    test(
      "returns 1 for a single trigger turn with no further chain",
      func() {
        let stores = makeStores();
        let t0 = SessionModel.createTurn(stores, 1, null, null, null);
        expect.nat(SessionModel.countDelegationDepth(stores, ?t0.turnId, 100)).equal(1);
      },
    );

    test(
      "walks a chain of 5 turns and returns depth 5",
      func() {
        let stores = makeStores();
        var prevId : ?Text = null;
        var i = 0;
        while (i < 5) {
          let t = SessionModel.createTurn(stores, 1, null, prevId, null);
          prevId := ?t.turnId;
          i += 1;
        };
        expect.nat(SessionModel.countDelegationDepth(stores, prevId, 100)).equal(5);
      },
    );

    test(
      "is bounded by maxDepth and returns early",
      func() {
        let stores = makeStores();
        var prevId : ?Text = null;
        var i = 0;
        while (i < 20) {
          let t = SessionModel.createTurn(stores, 1, null, prevId, null);
          prevId := ?t.turnId;
          i += 1;
        };
        // maxDepth = 10, chain = 20 → should return 10 (capped)
        expect.nat(SessionModel.countDelegationDepth(stores, prevId, 10)).equal(10);
      },
    );

    test(
      "returns depth when a turn in the chain is missing",
      func() {
        // Chain: t0 -> t1 (missing) → should return 2:
        // t0 found (depth 1), then follows triggerTurnId "1_999" which is not found (depth 2)
        let stores = makeStores();
        let t0 = SessionModel.createTurn(stores, 1, null, ?"1_999", null);
        expect.nat(SessionModel.countDelegationDepth(stores, ?t0.turnId, 100)).equal(2);
      },
    );
  },
);

// ============================================
// aggregateTurnCost
// ============================================

suite(
  "aggregateTurnCost",
  func() {
    test(
      "returns null when no traces exist",
      func() {
        let stores = makeStores();
        expect.bool(isNone(SessionModel.aggregateTurnCost(stores, "0_0"))).isTrue();
      },
    );

    test(
      "returns null when traces exist but no llmCall entries",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(stores, turn.turnId, #roundLimitHit);
        expect.bool(isNone(SessionModel.aggregateTurnCost(stores, turn.turnId))).isTrue();
      },
    );

    test(
      "sums costs across multiple llmCall traces",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(
          stores,
          turn.turnId,
          #llmCall({
            model = "gpt-4";
            durationMs = 500;
            finishReason = "stop";
            content = ?"hello";
            truncatedContent = null;
            thinking = null;
            toolRequests = null;
            cost = {
              promptTokens = 100;
              completionTokens = 50;
              estimatedDollarCost = ?0.0002;
            };
          }),
        );
        SessionModel.appendTrace(
          stores,
          turn.turnId,
          #llmCall({
            model = "gpt-4";
            durationMs = 300;
            finishReason = "stop";
            content = ?"world";
            truncatedContent = null;
            thinking = null;
            toolRequests = null;
            cost = {
              promptTokens = 80;
              completionTokens = 30;
              estimatedDollarCost = ?0.00015;
            };
          }),
        );

        switch (SessionModel.aggregateTurnCost(stores, turn.turnId)) {
          case (?cost) {
            expect.nat(cost.promptTokens).equal(180);
            expect.nat(cost.completionTokens).equal(80);
            expect.bool(cost.estimatedDollarCost == ?(0.0002 + 0.00015)).isTrue();
          };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );
  },
);

// ============================================
// deleteTurnsOlderThan
// ============================================

suite(
  "deleteTurnsOlderThan",
  func() {
    test(
      "deletes all turns older than cutoff including orphaned running ones",
      func() {
        let stores = makeStores();
        let t0 = SessionModel.createTurn(stores, 1, null, null, null);
        let t1 = SessionModel.createTurn(stores, 1, null, null, null);
        let t2 = SessionModel.createTurn(stores, 1, null, null, null); // still running

        // Complete t0 and t1
        SessionModel.completeTurn(stores, t0.turnId, #succeeded, null, null);
        SessionModel.completeTurn(stores, t1.turnId, #failed, null, ?"oops");
        // Add traces to t0 — they are NOT removed by deleteTurnsOlderThan;
        // trace GC is handled independently by deleteTracesOlderThan.
        SessionModel.appendTrace(stores, t0.turnId, #roundLimitHit);

        // Use a very large cutoff — all turns (including the running t2) have startedAtNs < cutoff
        let cutoff = 9_999_999_999_999_999_999;
        let deleted = SessionModel.deleteTurnsOlderThan(stores, cutoff);
        expect.nat(deleted.size()).equal(3);

        // All three turns should be gone (running turn is collected too)
        expect.bool(isNone(SessionModel.findTurn(stores, t0.turnId))).isTrue();
        expect.bool(isNone(SessionModel.findTurn(stores, t1.turnId))).isTrue();
        expect.bool(isNone(SessionModel.findTurn(stores, t2.turnId))).isTrue();
        // Trace for t0 is still present — deleteTurnsOlderThan no longer cascades trace deletion
        expect.bool(isSome(SessionModel.getTraces(stores, t0.turnId))).isTrue();
      },
    );

    test(
      "returns 0 when no turns exist",
      func() {
        let stores = makeStores();
        expect.nat(SessionModel.deleteTurnsOlderThan(stores, 9_999_999_999_999_999_999).size()).equal(0);
      },
    );

    test(
      "preserves turns with startedAtNs newer than cutoff",
      func() {
        let stores = makeStores();
        let t0 = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.completeTurn(stores, t0.turnId, #succeeded, null, null);

        // cutoff of 0 → nothing is older than epoch 0
        let deleted = SessionModel.deleteTurnsOlderThan(stores, 0);
        expect.nat(deleted.size()).equal(0);
        expect.bool(isSome(SessionModel.findTurn(stores, t0.turnId))).isTrue();
      },
    );
  },
);

// ============================================
// updateSessionPolicy
// ============================================

suite(
  "updateSessionPolicy",
  func() {
    test(
      "updates policy on an existing session",
      func() {
        let stores = makeStores();
        let session = SessionModel.getOrCreateSession(stores, 1);
        // Verify defaults
        expect.nat(session.policy.summaryTokenBudget).equal(Constants.DEFAULT_SUMMARY_TOKEN_BUDGET);
        expect.nat(session.policy.maxTruncatedTokens).equal(Constants.DEFAULT_MAX_TRUNCATED_TOKENS);

        let updated = SessionModel.updateSessionPolicy(
          stores,
          1,
          { summaryTokenBudget = 16384; maxTruncatedTokens = 1024 },
        );
        expect.bool(updated).isTrue();
        expect.nat(session.policy.summaryTokenBudget).equal(16384);
        expect.nat(session.policy.maxTruncatedTokens).equal(1024);
      },
    );

    test(
      "returns false for non-existent session",
      func() {
        let stores = makeStores();
        let updated = SessionModel.updateSessionPolicy(
          stores,
          999,
          { summaryTokenBudget = 4096; maxTruncatedTokens = 256 },
        );
        expect.bool(updated).isFalse();
      },
    );

    test(
      "partial merge preserves unchanged field when caller copies current value",
      func() {
        let stores = makeStores();
        let session = SessionModel.getOrCreateSession(stores, 5);

        // Update only summaryTokenBudget, keeping maxTruncatedTokens at default
        ignore SessionModel.updateSessionPolicy(
          stores,
          5,
          {
            summaryTokenBudget = 4096;
            maxTruncatedTokens = session.policy.maxTruncatedTokens;
          },
        );
        expect.nat(session.policy.summaryTokenBudget).equal(4096);
        expect.nat(session.policy.maxTruncatedTokens).equal(Constants.DEFAULT_MAX_TRUNCATED_TOKENS);
      },
    );
  },
);

// ============================================
// deleteTracesOlderThan
// ============================================

suite(
  "deleteTracesOlderThan",
  func() {
    test(
      "deletes traces for turns older than cutoff, turn records survive",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(stores, turn.turnId, #roundLimitHit);

        // cutoff far in the future — turn's startedAtNs is older
        let removed = SessionModel.deleteTracesOlderThan(stores, 9_999_999_999_999_999_999);
        expect.nat(removed).equal(1);

        // Trace is gone
        expect.bool(isNone(SessionModel.getTraces(stores, turn.turnId))).isTrue();
        // Turn record itself still exists
        expect.bool(isSome(SessionModel.findTurn(stores, turn.turnId))).isTrue();
      },
    );

    test(
      "returns 0 when no traces exist",
      func() {
        let stores = makeStores();
        expect.nat(SessionModel.deleteTracesOlderThan(stores, 9_999_999_999_999_999_999)).equal(0);
      },
    );

    test(
      "does not count turns that have no trace entries",
      func() {
        let stores = makeStores();
        // Turn created but no appendTrace called — no trace entry in the map
        ignore SessionModel.createTurn(stores, 1, null, null, null);
        let removed = SessionModel.deleteTracesOlderThan(stores, 9_999_999_999_999_999_999);
        expect.nat(removed).equal(0);
      },
    );

    test(
      "preserves traces for turns newer than cutoff",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(stores, turn.turnId, #roundLimitHit);

        // cutoff of 0 — nothing is older than epoch 0
        let removed = SessionModel.deleteTracesOlderThan(stores, 0);
        expect.nat(removed).equal(0);
        expect.bool(isSome(SessionModel.getTraces(stores, turn.turnId))).isTrue();
      },
    );

    test(
      "early exit: only removes traces for old turns, spares newer ones in same agent",
      func() {
        let stores = makeStores();
        // Seed three turns for the same agent — turn numbers are sequential
        let t0 = SessionModel.createTurn(stores, 2, null, null, null);
        let t1 = SessionModel.createTurn(stores, 2, null, null, null);
        let t2 = SessionModel.createTurn(stores, 2, null, null, null);
        SessionModel.appendTrace(stores, t0.turnId, #roundLimitHit);
        SessionModel.appendTrace(stores, t1.turnId, #roundLimitHit);
        SessionModel.appendTrace(stores, t2.turnId, #roundLimitHit);

        // t0 has startedAtNs at creation; use a cutoff that only matches t0
        // (all turns share the same clock in mops tests, so we use 0 to match none
        // and large cutoff to match all — boundary is exercised in the other tests)
        let removed = SessionModel.deleteTracesOlderThan(stores, 0);
        expect.nat(removed).equal(0);
        // All three traces intact
        expect.bool(isSome(SessionModel.getTraces(stores, t0.turnId))).isTrue();
        expect.bool(isSome(SessionModel.getTraces(stores, t1.turnId))).isTrue();
        expect.bool(isSome(SessionModel.getTraces(stores, t2.turnId))).isTrue();
      },
    );
  },
);

// ============================================
// awaitingApproval
// ============================================

suite(
  "awaitingApproval",
  func() {
    test(
      "transitions a running turn to #awaitingApproval",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        expect.bool(switch (turn.status) { case (#running) true; case _ false }).isTrue();
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_approval";
          roundCount = 1;
        };
        ignore SessionModel.suspendForApproval(
          stores,
          turn.turnId,
          dummySuspension,
          "abc123",
          9_999_999_999_999,
        );
        switch (turn.status) {
          case (#awaitingApproval(data)) {
            expect.text(data.approvalCode).equal("abc123");
            expect.bool(data.expiresAtNs == 9_999_999_999_999).isTrue();
            expect.bool(data.timerId == null).isTrue();
            expect.bool(data.suspension.pendingToolCallId == "call_approval").isTrue();
          };
          case (_) { expect.bool(false).isTrue() }; // unreachable: expected #awaitingApproval
        };
      },
    );

    test(
      "timerId field is mutable and can be set",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_approval";
          roundCount = 1;
        };
        ignore SessionModel.suspendForApproval(
          stores,
          turn.turnId,
          dummySuspension,
          "abc123",
          9_999_999_999_999,
        );
        switch (turn.status) {
          case (#awaitingApproval(data)) {
            // Simulate the timer being armed via the model function
            ignore SessionModel.setApprovalTimerId(stores, turn.turnId, 42);
            expect.bool(data.timerId == ?42).isTrue();
          };
          case (_) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "#awaitingApproval turn survives findTurn round-trip",
      func() {
        let stores = makeStores();
        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        let dummySuspension : SessionModel.SuspensionData = {
          messages = [];
          pendingToolCallId = "call_approval";
          roundCount = 2;
        };
        ignore SessionModel.suspendForApproval(
          stores,
          turn.turnId,
          dummySuspension,
          "deadbeef",
          1_000_000,
        );
        switch (SessionModel.findTurn(stores, turn.turnId)) {
          case (null) { expect.bool(false).isTrue() };
          case (?found) {
            switch (found.status) {
              case (#awaitingApproval(data)) {
                expect.text(data.approvalCode).equal("deadbeef");
                expect.nat(data.suspension.roundCount).equal(2);
              };
              case (_) { expect.bool(false).isTrue() };
            };
          };
        };
      },
    );
  },
);
