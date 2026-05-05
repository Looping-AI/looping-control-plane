import { test; suite; expect } "mo:test";
import ExecutionEnvelopeModel "../../../../src/control-plane-core/models/execution-envelope-model";
import ExecutionTypes "../../../../src/control-plane-core/types/execution";

// ============================================
// Helpers
// ============================================

func makeStore() : ExecutionEnvelopeModel.EnvelopeState {
  ExecutionEnvelopeModel.emptyState();
};

let workspaceGrant : ExecutionTypes.ScopeGrant = #workspace({ access = #write });
let agentsReadGrant : ExecutionTypes.ScopeGrant = #agents({ access = #read });
let slackQueueGrant : ExecutionTypes.ScopeGrant = #slackQueue({
  access = #write;
});
let sessionGrant : ExecutionTypes.ScopeGrant = #session({ access = #write });

func issueBasic(store : ExecutionEnvelopeModel.EnvelopeState) : Text {
  ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant]).nonce;
};

// ============================================
// emptyStore
// ============================================

suite(
  "emptyStore",
  func() {
    test(
      "starts with nextTokenId = 0",
      func() {
        let store = makeStore();
        expect.nat(store.nextTokenId).equal(0);
      },
    );
  },
);

// ============================================
// issue
// ============================================

suite(
  "issue",
  func() {
    test(
      "returns a non-empty nonce",
      func() {
        let store = makeStore();
        let nonce = issueBasic(store);
        expect.bool(nonce.size() > 0).isTrue();
      },
    );

    test(
      "increments nextTokenId on each call",
      func() {
        let store = makeStore();
        let n0 = issueBasic(store);
        let n1 = issueBasic(store);
        let n2 = issueBasic(store);
        expect.bool(n0.size() == 64).isTrue();
        expect.bool(n1.size() == 64).isTrue();
        expect.bool(n2.size() == 64).isTrue();
        expect.bool(n0 != n1 and n1 != n2).isTrue();
        expect.nat(store.nextTokenId).equal(3);
      },
    );

    test(
      "nonces are unique across issues",
      func() {
        let store = makeStore();
        let n0 = issueBasic(store);
        let n1 = issueBasic(store);
        expect.bool(n0 != n1).isTrue();
      },
    );
  },
);

// ============================================
// validate — scope coverage
// ============================================

suite(
  "validate — scope coverage",
  func() {
    test(
      "returns true when token carries the exact required grant",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant]).nonce;
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isTrue();
      },
    );

    test(
      "write grant covers read requirement on same scope",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant]).nonce;
        // Token has #write; requiring #read should be satisfied
        expect.bool(
          ExecutionEnvelopeModel.validate(store, nonce, #workspace({ access = #read }))
        ).isTrue();
      },
    );

    test(
      "read grant does NOT cover write requirement on same scope",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(
          store,
          "1_0",
          1,
          [#workspace({ access = #read })],
        ).nonce;
        expect.bool(
          ExecutionEnvelopeModel.validate(store, nonce, #workspace({ access = #write }))
        ).isFalse();
      },
    );

    test(
      "wrong scope type is rejected",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant]).nonce;
        // Token only has #workspace, not #agents
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, agentsReadGrant)).isFalse();
      },
    );

    test(
      "returns false for unknown nonce",
      func() {
        let store = makeStore();
        expect.bool(ExecutionEnvelopeModel.validate(store, "does-not-exist", workspaceGrant)).isFalse();
      },
    );

    test(
      "token with multiple grants satisfies any of them",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(
          store,
          "1_0",
          1,
          [workspaceGrant, agentsReadGrant, slackQueueGrant],
        ).nonce;
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isTrue();
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, agentsReadGrant)).isTrue();
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, slackQueueGrant)).isTrue();
        // Still rejects a grant not in the list
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, sessionGrant)).isFalse();
      },
    );

    test(
      "per-agent grant matches on exact id and access",
      func() {
        let store = makeStore();
        let agentGrant : ExecutionTypes.ScopeGrant = #agent({
          id = 7;
          access = #write;
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [agentGrant]).nonce;
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, #agent({ id = 7; access = #write }))).isTrue();
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, #agent({ id = 7; access = #read }))).isTrue();
        // Wrong agent id
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, #agent({ id = 99; access = #write }))).isFalse();
      },
    );
  },
);

// ============================================
// revoke
// ============================================

suite(
  "revoke",
  func() {
    test(
      "revoked token fails validation",
      func() {
        let store = makeStore();
        let nonce = issueBasic(store);
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isTrue();
        ExecutionEnvelopeModel.revoke(store, nonce);
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isFalse();
      },
    );

    test(
      "revoke is idempotent — no trap on second call",
      func() {
        let store = makeStore();
        let nonce = issueBasic(store);
        ExecutionEnvelopeModel.revoke(store, nonce);
        ExecutionEnvelopeModel.revoke(store, nonce); // should not trap
      },
    );

    test(
      "revoke on unknown nonce is a no-op",
      func() {
        let store = makeStore();
        ExecutionEnvelopeModel.revoke(store, "ghost"); // should not trap
      },
    );

    test(
      "getRecord returns null after revoke",
      func() {
        let store = makeStore();
        let nonce = issueBasic(store);
        ExecutionEnvelopeModel.revoke(store, nonce);
        switch (ExecutionEnvelopeModel.getRecord(store, nonce)) {
          case (null) {}; // expected
          case (?_) { expect.bool(false).isTrue() };
        };
      },
    );
  },
);

// ============================================
// getRecord
// ============================================

suite(
  "getRecord",
  func() {
    test(
      "returns the token record for a valid nonce",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "2_0", 3, [workspaceGrant]).nonce;
        switch (ExecutionEnvelopeModel.getRecord(store, nonce)) {
          case (?record) {
            expect.nat(record.envelopeId).equal(0);
            expect.text(record.turnId).equal("2_0");
            expect.nat(record.workspaceId).equal(3);
          };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "returns null for unknown nonce",
      func() {
        let store = makeStore();
        switch (ExecutionEnvelopeModel.getRecord(store, "none")) {
          case (null) {}; // expected
          case (?_) { expect.bool(false).isTrue() };
        };
      },
    );
  },
);

// ============================================
// deleteEnvelopesOlderThan
// ============================================

suite(
  "deleteEnvelopesOlderThan",
  func() {
    test(
      "returns 0 on empty store",
      func() {
        let store = makeStore();
        expect.nat(ExecutionEnvelopeModel.deleteEnvelopesOlderThan(store, 1)).equal(0);
      },
    );

    test(
      "removes envelopes with createdAtNs before cutoff and returns count",
      func() {
        let store = makeStore();
        ignore issueBasic(store);
        ignore issueBasic(store);
        // Use a cutoff far in the future so createdAtNs (Time.now()) is always older
        let removed = ExecutionEnvelopeModel.deleteEnvelopesOlderThan(store, 9_999_999_999_999_999_999);
        expect.nat(removed).equal(2);
        expect.nat(store.nextTokenId).equal(2); // counter untouched
      },
    );

    test(
      "preserves envelopes with createdAtNs >= cutoff",
      func() {
        let store = makeStore();
        let nonce = issueBasic(store);
        // cutoff of 0 — createdAtNs (Time.now(), a positive value) is not < 0, so nothing removed
        let removed = ExecutionEnvelopeModel.deleteEnvelopesOlderThan(store, 0);
        expect.nat(removed).equal(0);
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isTrue();
      },
    );

    test(
      "is idempotent — second call on same store returns 0",
      func() {
        let store = makeStore();
        ignore issueBasic(store);
        ignore ExecutionEnvelopeModel.deleteEnvelopesOlderThan(store, 9_999_999_999_999_999_999);
        let removed2 = ExecutionEnvelopeModel.deleteEnvelopesOlderThan(store, 9_999_999_999_999_999_999);
        expect.nat(removed2).equal(0);
      },
    );
  },
);
