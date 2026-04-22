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
  ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], []).nonce;
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
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], []).nonce;
        expect.bool(ExecutionEnvelopeModel.validate(store, nonce, workspaceGrant)).isTrue();
      },
    );

    test(
      "write grant covers read requirement on same scope",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], []).nonce;
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
          [],
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
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], []).nonce;
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
          [],
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
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [agentGrant], []).nonce;
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
// hasPermit
// ============================================

suite(
  "hasPermit",
  func() {
    test(
      "returns true for matching deleteWorkspace permit",
      func() {
        let store = makeStore();
        let permit : ExecutionTypes.OperationPermit = #deleteWorkspace({
          workspaceId = 5;
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], [permit]).nonce;
        expect.bool(ExecutionEnvelopeModel.hasPermit(store, nonce, permit)).isTrue();
      },
    );

    test(
      "returns false when workspaceId does not match",
      func() {
        let store = makeStore();
        let permit : ExecutionTypes.OperationPermit = #deleteWorkspace({
          workspaceId = 5;
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], [permit]).nonce;
        expect.bool(
          ExecutionEnvelopeModel.hasPermit(store, nonce, #deleteWorkspace({ workspaceId = 99 }))
        ).isFalse();
      },
    );

    test(
      "returns true for matching setAdminChannel permit",
      func() {
        let store = makeStore();
        let permit : ExecutionTypes.OperationPermit = #setAdminChannel({
          channelId = "C_ADMIN";
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [sessionGrant], [permit]).nonce;
        expect.bool(ExecutionEnvelopeModel.hasPermit(store, nonce, permit)).isTrue();
      },
    );

    test(
      "returns false when channelId does not match",
      func() {
        let store = makeStore();
        let permit : ExecutionTypes.OperationPermit = #setAdminChannel({
          channelId = "C_ADMIN";
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [sessionGrant], [permit]).nonce;
        expect.bool(
          ExecutionEnvelopeModel.hasPermit(store, nonce, #setAdminChannel({ channelId = "C_OTHER" }))
        ).isFalse();
      },
    );

    test(
      "returns false when token has no permits",
      func() {
        let store = makeStore();
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], []).nonce;
        expect.bool(
          ExecutionEnvelopeModel.hasPermit(store, nonce, #deleteWorkspace({ workspaceId = 1 }))
        ).isFalse();
      },
    );

    test(
      "returns false for revoked token even with matching permit",
      func() {
        let store = makeStore();
        let permit : ExecutionTypes.OperationPermit = #deleteWorkspace({
          workspaceId = 1;
        });
        let nonce = ExecutionEnvelopeModel.issue(store, "1_0", 1, [workspaceGrant], [permit]).nonce;
        ExecutionEnvelopeModel.revoke(store, nonce);
        expect.bool(ExecutionEnvelopeModel.hasPermit(store, nonce, permit)).isFalse();
      },
    );

    test(
      "returns false for unknown nonce",
      func() {
        let store = makeStore();
        expect.bool(
          ExecutionEnvelopeModel.hasPermit(store, "ghost", #deleteWorkspace({ workspaceId = 1 }))
        ).isFalse();
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
        let nonce = ExecutionEnvelopeModel.issue(store, "2_0", 3, [workspaceGrant], []).nonce;
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
