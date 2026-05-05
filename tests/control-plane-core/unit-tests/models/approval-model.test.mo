import { test; suite; expect } "mo:test";
import Set "mo:core/Set";
import Nat "mo:core/Nat";
import ApprovalModel "../../../../src/control-plane-core/models/approval-model";

// ============================================
// Helpers
// ============================================

func makeState() : ApprovalModel.ApprovalState {
  ApprovalModel.emptyState();
};

// ============================================
// request
// ============================================

suite(
  "request",
  func() {
    test(
      "returns a non-empty code",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        expect.bool(code.size() > 0).isTrue();
      },
    );

    test(
      "stores record with correct fields",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{\"arg\":1}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() }; // expected a record
          case (?record) {
            expect.text(record.code).equal(code);
            expect.text(record.workflowName).equal("deploy");
            expect.text(record.originalArgs).equal("{\"arg\":1}");
            expect.nat(record.workspaceId).equal(1);
            expect.nat(record.agentId).equal(2);
            expect.text(record.turnId).equal("1_0");
            expect.text(record.requestedByUserId).equal("U_REQ");
            expect.bool(switch (record.status) { case (#pending) true; case _ false }).isTrue();
          };
        };
      },
    );

    test(
      "two requests produce different codes",
      func() {
        let state = makeState();
        let code1 = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        let code2 = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_1", "U_REQ");
        expect.bool(code1 != code2).isTrue();
      },
    );

  },
);

// ============================================
// findByCode
// ============================================

suite(
  "findByCode",
  func() {
    test(
      "returns null for unknown code",
      func() {
        let state = makeState();
        let result = ApprovalModel.findByCode(state, "no-such-code");
        expect.bool(switch (result) { case (null) true; case (_) false }).isTrue();
      },
    );

    test(
      "returns the record for a known code",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            expect.text(record.workflowName).equal("deploy");
          };
        };
      },
    );
  },
);

// ============================================
// isApprovalWindowExpired
// ============================================

suite(
  "isApprovalWindowExpired",
  func() {
    test(
      "returns false when now equals requestedAt",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            expect.bool(not ApprovalModel.isApprovalWindowExpired(record, record.requestedAt)).isTrue();
          };
        };
      },
    );

    test(
      "returns true when now is far in the future",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            let farFuture = record.requestedAt + 999_999_999_999_999_999;
            expect.bool(ApprovalModel.isApprovalWindowExpired(record, farFuture)).isTrue();
          };
        };
      },
    );
  },
);

// ============================================
// isExecutionWindowExpired
// ============================================

suite(
  "isExecutionWindowExpired",
  func() {
    test(
      "returns false when now equals requestedAt",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            expect.bool(not ApprovalModel.isExecutionWindowExpired(record, record.requestedAt)).isTrue();
          };
        };
      },
    );

    test(
      "returns true when now is far in the future",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            let farFuture = record.requestedAt + 999_999_999_999_999_999;
            expect.bool(ApprovalModel.isExecutionWindowExpired(record, farFuture)).isTrue();
          };
        };
      },
    );
  },
);

// ============================================
// approve
// ============================================

suite(
  "approve",
  func() {
    test(
      "succeeds and marks record #approved for correct user",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.approve(state, code, "U_REQ", Set.empty())) {
          case (#err(_)) { expect.bool(false).isTrue() }; // unexpected error
          case (#ok(record)) {
            expect.text(record.code).equal(code);
            expect.bool(switch (record.status) { case (#approved) true; case _ false }).isTrue();
          };
        };
      },
    );

    test(
      "rejects unknown code",
      func() {
        let state = makeState();
        switch (ApprovalModel.approve(state, "no-such-code", "U_REQ", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects wrong requestedByUserId",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        switch (ApprovalModel.approve(state, code, "U_OTHER", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects already-approved code",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        ignore ApprovalModel.approve(state, code, "U_REQ", Set.empty());
        // Second call: already #approved
        switch (ApprovalModel.approve(state, code, "U_REQ", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "succeeds for a workspace admin (adminWorkspaces contains workspaceId)",
      func() {
        let state = makeState();
        // workspaceId = 1 comes from the request() call below.
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        let adminSet = Set.fromIter([1].values(), Nat.compare);
        switch (ApprovalModel.approve(state, code, "U_ADMIN", adminSet)) {
          case (#err(_)) { expect.bool(false).isTrue() }; // unexpected error
          case (#ok(record)) {
            expect.bool(switch (record.status) { case (#approved) true; case _ false }).isTrue();
          };
        };
      },
    );

    test(
      "rejects non-requester with empty adminWorkspaces",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        switch (ApprovalModel.approve(state, code, "U_ADMIN", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects non-requester when adminWorkspaces contains a different workspaceId",
      func() {
        let state = makeState();
        // Record has workspaceId = 1; admin set contains 99 — no match.
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        let adminSet = Set.fromIter([99].values(), Nat.compare);
        switch (ApprovalModel.approve(state, code, "U_ADMIN", adminSet)) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );
  },
);

// ============================================
// deny
// ============================================

suite(
  "deny",
  func() {
    test(
      "succeeds and marks record #denied for correct user",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.deny(state, code, "U_REQ", Set.empty())) {
          case (#err(_)) { expect.bool(false).isTrue() }; // unexpected error
          case (#ok(record)) {
            expect.bool(switch (record.status) { case (#denied) true; case _ false }).isTrue();
          };
        };
      },
    );

    test(
      "succeeds for a workspace admin (adminWorkspaces contains workspaceId)",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        let adminSet = Set.fromIter([1].values(), Nat.compare);
        switch (ApprovalModel.deny(state, code, "U_ADMIN", adminSet)) {
          case (#err(_)) { expect.bool(false).isTrue() }; // unexpected error
          case (#ok(record)) {
            expect.bool(switch (record.status) { case (#denied) true; case _ false }).isTrue();
          };
        };
      },
    );

    test(
      "rejects non-requester with empty adminWorkspaces",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_OWNER");
        switch (ApprovalModel.deny(state, code, "U_ADMIN", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects unknown code",
      func() {
        let state = makeState();
        switch (ApprovalModel.deny(state, "no-such-code", "U_REQ", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects already-denied code",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        ignore ApprovalModel.deny(state, code, "U_REQ", Set.empty());
        switch (ApprovalModel.deny(state, code, "U_REQ", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );

    test(
      "rejects already-approved code",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        ignore ApprovalModel.approve(state, code, "U_REQ", Set.empty());
        switch (ApprovalModel.deny(state, code, "U_REQ", Set.empty())) {
          case (#ok(_)) { expect.bool(false).isTrue() }; // unexpected success
          case (#err(_)) {};
        };
      },
    );
  },
);

// ============================================
// Status lifecycle
// ============================================

suite(
  "status lifecycle",
  func() {
    test(
      "direct status mutation to #used is reflected on same record ref",
      func() {
        let state = makeState();
        let code = ApprovalModel.request(state, "deploy", "{}", 1, 2, "1_0", "U_REQ");
        switch (ApprovalModel.findByCode(state, code)) {
          case (null) { expect.bool(false).isTrue() };
          case (?record) {
            record.status := #approved;
            expect.bool(switch (record.status) { case (#approved) true; case _ false }).isTrue();
            // Verify it's visible via a fresh lookup (same mutable ref)
            switch (ApprovalModel.findByCode(state, code)) {
              case (null) { expect.bool(false).isTrue() };
              case (?r2) {
                expect.bool(switch (r2.status) { case (#approved) true; case _ false }).isTrue();
              };
            };
          };
        };
      },
    );
  },
);
