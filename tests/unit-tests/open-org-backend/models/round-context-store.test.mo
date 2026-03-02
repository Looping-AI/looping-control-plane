import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import RoundContextStore "../../../../src/open-org-backend/models/round-context-store";
import SlackAuthMiddleware "../../../../src/open-org-backend/middleware/slack-auth-middleware";
import SlackUserModel "../../../../src/open-org-backend/models/slack-user-model";

// ============================================
// Helpers
// ============================================

/// Build a minimal UserAuthContext for testing.
func makeCtx(slackUserId : Text, roundCount : Nat, forceTerminated : Bool) : SlackAuthMiddleware.UserAuthContext {
  {
    slackUserId;
    isPrimaryOwner = false;
    isOrgAdmin = false;
    workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    roundCount;
    forceTerminated;
  };
};

// ============================================
// Suite: empty store
// ============================================

suite(
  "RoundContextStore - empty",
  func() {

    test(
      "lookup on empty store returns null",
      func() {
        let store = RoundContextStore.empty();
        expect.option<RoundContextStore.UserAuthContext>(
          RoundContextStore.lookup(store, "1700000000.000001"),
          func(ctx) { ctx.slackUserId },
          func(a, b) { a.slackUserId == b.slackUserId },
        ).isNull();
      },
    );

  },
);

// ============================================
// Suite: save and lookup
// ============================================

suite(
  "RoundContextStore - save and lookup",
  func() {

    test(
      "saved context can be retrieved by threadTs",
      func() {
        let store = RoundContextStore.empty();
        let ctx = makeCtx("U_ALICE", 0, false);
        RoundContextStore.save(store, "1700000000.000001", ctx);

        let result = RoundContextStore.lookup(store, "1700000000.000001");
        switch (result) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) {
            expect.text(found.slackUserId).equal("U_ALICE");
            expect.nat(found.roundCount).equal(0);
            expect.bool(found.forceTerminated).equal(false);
          };
        };
      },
    );

    test(
      "different threads store independent contexts",
      func() {
        let store = RoundContextStore.empty();
        RoundContextStore.save(store, "thread-A", makeCtx("U_ALICE", 1, false));
        RoundContextStore.save(store, "thread-B", makeCtx("U_BOB", 5, false));

        switch (RoundContextStore.lookup(store, "thread-A")) {
          case (null) { expect.bool(false).equal(true) };
          case (?a) {
            expect.text(a.slackUserId).equal("U_ALICE");
            expect.nat(a.roundCount).equal(1);
          };
        };
        switch (RoundContextStore.lookup(store, "thread-B")) {
          case (null) { expect.bool(false).equal(true) };
          case (?b) {
            expect.text(b.slackUserId).equal("U_BOB");
            expect.nat(b.roundCount).equal(5);
          };
        };
      },
    );

    test(
      "save overwrites the previous context for a thread",
      func() {
        let store = RoundContextStore.empty();
        let ctx0 = makeCtx("U_ALICE", 0, false);
        let ctx1 = makeCtx("U_ALICE", 3, false);
        RoundContextStore.save(store, "thread-A", ctx0);
        RoundContextStore.save(store, "thread-A", ctx1);

        switch (RoundContextStore.lookup(store, "thread-A")) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) { expect.nat(found.roundCount).equal(3) };
        };
      },
    );

    test(
      "lookup for unknown threadTs returns null even when other threads are stored",
      func() {
        let store = RoundContextStore.empty();
        RoundContextStore.save(store, "known-thread", makeCtx("U_ALICE", 0, false));

        expect.option<RoundContextStore.UserAuthContext>(
          RoundContextStore.lookup(store, "unknown-thread"),
          func(ctx) { ctx.slackUserId },
          func(a, b) { a.slackUserId == b.slackUserId },
        ).isNull();
      },
    );

  },
);

// ============================================
// Suite: round-count evolution via withRound
// ============================================

suite(
  "RoundContextStore - round-count evolution",
  func() {

    test(
      "roundCount increments correctly across saves",
      func() {
        let store = RoundContextStore.empty();
        let threadTs = "1700000005.000001";

        // Seed at round 0 (user message)
        let ctx0 = makeCtx("U_ALICE", 0, false);
        RoundContextStore.save(store, threadTs, ctx0);

        // Advance to round 1 (bot message)
        let ctx1 = SlackAuthMiddleware.withRound(ctx0, 1, false);
        RoundContextStore.save(store, threadTs, ctx1);

        switch (RoundContextStore.lookup(store, threadTs)) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) {
            expect.nat(found.roundCount).equal(1);
            expect.bool(found.forceTerminated).equal(false);
          };
        };

        // Advance to round 2
        let ctx2 = SlackAuthMiddleware.withRound(ctx1, 2, false);
        RoundContextStore.save(store, threadTs, ctx2);

        switch (RoundContextStore.lookup(store, threadTs)) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) { expect.nat(found.roundCount).equal(2) };
        };
      },
    );

    test(
      "forceTerminated flag is preserved after save",
      func() {
        let store = RoundContextStore.empty();
        let threadTs = "thread-terminated";
        let ctx = makeCtx("U_ALICE", 99, true);
        RoundContextStore.save(store, threadTs, ctx);

        switch (RoundContextStore.lookup(store, threadTs)) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) {
            expect.nat(found.roundCount).equal(99);
            expect.bool(found.forceTerminated).equal(true);
          };
        };
      },
    );

  },
);

// ============================================
// Suite: withRound helper (from SlackAuthMiddleware)
// ============================================

suite(
  "RoundContextStore - withRound integration",
  func() {

    test(
      "withRound produces a new context with updated roundCount and forceTerminated",
      func() {
        let original = makeCtx("U_ALICE", 0, false);

        let round5 = SlackAuthMiddleware.withRound(original, 5, false);
        expect.nat(round5.roundCount).equal(5);
        expect.bool(round5.forceTerminated).equal(false);
        expect.text(round5.slackUserId).equal("U_ALICE"); // identity preserved

        let terminated = SlackAuthMiddleware.withRound(round5, 6, true);
        expect.nat(terminated.roundCount).equal(6);
        expect.bool(terminated.forceTerminated).equal(true);
        expect.text(terminated.slackUserId).equal("U_ALICE");
      },
    );

  },
);
