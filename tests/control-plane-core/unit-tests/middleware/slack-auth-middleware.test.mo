import { test; suite; expect } "mo:test";
import Set "mo:core/Set";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import SlackUserModel "../../../../src/control-plane-core/models/slack-user-model";
import SlackAuthMiddleware "../../../../src/control-plane-core/middleware/slack-auth-middleware";

// ============================================
// Test Slack User IDs
// ============================================

let primaryOwner = "U001";
let orgAdmin1 = "U002";
let orgAdmin2 = "U003";
let workspaceAdmin1 = "U004";
let workspaceAdmin2 = "U005";
let regularUser = "U006";
let unknownUser = "U999";

// ============================================
// Helper Functions
// ============================================

func resultToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

/// Build a test cache with predefined users and memberships
func buildTestCache() : SlackUserModel.SlackUserCache {
  let state = SlackUserModel.emptyState();

  // Primary Owner: isPrimaryOwner=true, isOrgAdmin=false
  let primaryOwnerEntry = SlackUserModel.newEntry(primaryOwner, "Alice (Primary Owner)", true, false, false);
  SlackUserModel.upsertUser(state, primaryOwnerEntry, #manual);

  // Org Admins: isPrimaryOwner=false, isOrgAdmin=true
  let orgAdmin1Entry = SlackUserModel.newEntry(orgAdmin1, "Bob (Org Admin)", false, true, false);
  SlackUserModel.upsertUser(state, orgAdmin1Entry, #manual);

  let orgAdmin2Entry = SlackUserModel.newEntry(orgAdmin2, "Carol (Org Admin)", false, true, false);
  SlackUserModel.upsertUser(state, orgAdmin2Entry, #manual);

  // Workspace Admins: joined the admin-channel anchor
  var wsAdmin1Entry = SlackUserModel.newEntry(workspaceAdmin1, "Dave (WS Admin)", false, false, false);
  SlackUserModel.upsertUser(state, wsAdmin1Entry, #manual);
  ignore SlackUserModel.joinAdminChannel(state, workspaceAdmin1, 0, #manual);

  var wsAdmin2Entry = SlackUserModel.newEntry(workspaceAdmin2, "Eve (WS Admin)", false, false, false);
  SlackUserModel.upsertUser(state, wsAdmin2Entry, #manual);
  ignore SlackUserModel.joinAdminChannel(state, workspaceAdmin2, 1, #manual);

  // Regular user: no special roles or workspace memberships
  let regularUserEntry = SlackUserModel.newEntry(regularUser, "Frank (Regular)", false, false, false);
  SlackUserModel.upsertUser(state, regularUserEntry, #manual);

  state.cache;
};

// ============================================
// Suite: buildFromCache
// ============================================

suite(
  "SlackAuthMiddleware - buildFromCache",
  func() {
    test(
      "should build UserAuthContext for a primary owner",
      func() {
        let cache = buildTestCache();
        switch (SlackAuthMiddleware.buildFromCache(primaryOwner, cache)) {
          case (null) { expect.bool(false).equal(true) }; // force fail
          case (?ctx) {
            expect.text(ctx.slackUserId).equal(primaryOwner);
            expect.bool(ctx.isPrimaryOwner).equal(true);
            expect.bool(ctx.isOrgAdmin).equal(false);
          };
        };
      },
    );

    test(
      "should build UserAuthContext for an org admin",
      func() {
        let cache = buildTestCache();
        switch (SlackAuthMiddleware.buildFromCache(orgAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true) };
          case (?ctx) {
            expect.text(ctx.slackUserId).equal(orgAdmin1);
            expect.bool(ctx.isPrimaryOwner).equal(false);
            expect.bool(ctx.isOrgAdmin).equal(true);
          };
        };
      },
    );

    test(
      "should include workspace memberships in the context",
      func() {
        let cache = buildTestCache();
        switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true) };
          case (?ctx) {
            // workspaceAdmin1 has admin membership in workspace 0
            expect.bool(Set.contains(ctx.adminWorkspaces, Nat.compare, 0)).equal(true);
          };
        };
      },
    );

    test(
      "should return null for unknown user",
      func() {
        let cache = buildTestCache();
        let result = SlackAuthMiddleware.buildFromCache(unknownUser, cache);
        expect.option<SlackAuthMiddleware.UserAuthContext>(
          result,
          func(ctx : SlackAuthMiddleware.UserAuthContext) : Text {
            ctx.slackUserId;
          },
          func(a : SlackAuthMiddleware.UserAuthContext, b : SlackAuthMiddleware.UserAuthContext) : Bool {
            a.slackUserId == b.slackUserId;
          },
        ).isNull();
      },
    );
  },
);

// ============================================
// Suite: withRound
// ============================================
// Suite: authorize - IsPrimaryOwner
// ============================================

suite(
  "SlackAuthMiddleware.authorize - IsPrimaryOwner",
  func() {
    test(
      "should allow primary owner",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(primaryOwner, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsPrimaryOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject org admin when requiring primary owner",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(orgAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsPrimaryOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: authorize - IsOrgAdmin
// ============================================

suite(
  "SlackAuthMiddleware.authorize - IsOrgAdmin",
  func() {
    test(
      "should allow primary owner as org admin",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(primaryOwner, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow org admin",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(orgAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject regular user",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: authorize - IsWorkspaceAdmin
// ============================================

suite(
  "SlackAuthMiddleware.authorize - IsWorkspaceAdmin",
  func() {
    test(
      "should allow workspace admin of specified workspace",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject non-admin user",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isErr();
        switch (result) {
          case (#err(msg)) {
            expect.bool(Text.contains(msg, #text "workspace 0")).equal(true);
          };
          case (#ok(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "should reject admin of different workspace",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceAdmin1 is admin of workspace 0, not workspace 1
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(1)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isErr();
        switch (result) {
          case (#err(msg)) {
            expect.bool(Text.contains(msg, #text "workspace 1")).equal(true);
          };
          case (#ok(_)) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

// ============================================
// Suite: authorize - OR Logic (multiple steps)
// ============================================

suite(
  "SlackAuthMiddleware.authorize - OR Logic",
  func() {
    test(
      "should pass workspace admin check",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceAdmin1 is #admin of workspace 0
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject when no step matches",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // regularUser has no workspace access, so the workspace 1 check fails
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(1)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isErr();
        switch (result) {
          case (#err(msg)) {
            expect.bool(Text.contains(msg, #text "workspace 1")).equal(true);
          };
          case (#ok(_)) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

// ============================================
// Suite: authorize - Error Message Consolidation
// ============================================

suite(
  "SlackAuthMiddleware.authorize - Error consolidation",
  func() {
    test(
      "should consolidate multiple role errors into comma-separated list",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(
          ctx,
          [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(0)],
        );
        switch (result) {
          case (#ok(_)) { expect.bool(false).equal(true) }; // should fail
          case (#err(msg)) {
            // Should consolidate role-based errors
            expect.bool(Text.contains(msg, #text "Only")).equal(true);
            expect.bool(Text.contains(msg, #text "can perform this action")).equal(true);
          };
        };
      },
    );

    test(
      "should return single error message when only one step",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsPrimaryOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Only Primary Owner can perform this action.")
        );
      },
    );

    test(
      "should include workspace ID in error for workspace-scoped checks",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(regularUser, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(2)]);
        switch (result) {
          case (#ok(_)) { expect.bool(false).equal(true) }; // should fail
          case (#err(msg)) {
            expect.bool(Text.contains(msg, #text "workspace 2")).equal(true);
            expect.bool(Text.contains(msg, #text "admins")).equal(true);
          };
        };
      },
    );
  },
);
