import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import SlackUserModel "../../../../src/open-org-backend/models/slack-user-model";
import SlackAuthMiddleware "../../../../src/open-org-backend/middleware/slack-auth-middleware";

// ============================================
// Test Slack User IDs
// ============================================

let primaryOwner = "U001";
let orgAdmin1 = "U002";
let orgAdmin2 = "U003";
let workspaceAdmin1 = "U004";
let workspaceAdmin2 = "U005";
let workspaceMember1 = "U006";
let workspaceMember2 = "U007";
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
  let cache = SlackUserModel.empty();

  // Primary Owner: isPrimaryOwner=true, isOrgAdmin=false
  let primaryOwnerEntry = SlackUserModel.newEntry(primaryOwner, "Alice (Primary Owner)", true, false);
  SlackUserModel.upsertUser(cache, primaryOwnerEntry);

  // Org Admins: isPrimaryOwner=false, isOrgAdmin=true
  let orgAdmin1Entry = SlackUserModel.newEntry(orgAdmin1, "Bob (Org Admin)", false, true);
  SlackUserModel.upsertUser(cache, orgAdmin1Entry);

  let orgAdmin2Entry = SlackUserModel.newEntry(orgAdmin2, "Carol (Org Admin)", false, true);
  SlackUserModel.upsertUser(cache, orgAdmin2Entry);

  // Workspace Admins: memberships with #admin scope
  var wsAdmin1Entry = SlackUserModel.newEntry(workspaceAdmin1, "Dave (WS Admin)", false, false);
  SlackUserModel.upsertUser(cache, wsAdmin1Entry);
  ignore SlackUserModel.updateWorkspaceMembership(cache, workspaceAdmin1, 0, #admin);

  var wsAdmin2Entry = SlackUserModel.newEntry(workspaceAdmin2, "Eve (WS Admin)", false, false);
  SlackUserModel.upsertUser(cache, wsAdmin2Entry);
  ignore SlackUserModel.updateWorkspaceMembership(cache, workspaceAdmin2, 1, #admin);

  // Workspace Members: memberships with #member scope
  var wsMember1Entry = SlackUserModel.newEntry(workspaceMember1, "Frank (Member)", false, false);
  SlackUserModel.upsertUser(cache, wsMember1Entry);
  ignore SlackUserModel.updateWorkspaceMembership(cache, workspaceMember1, 0, #member);

  var wsMember2Entry = SlackUserModel.newEntry(workspaceMember2, "Grace (Member)", false, false);
  SlackUserModel.upsertUser(cache, wsMember2Entry);
  ignore SlackUserModel.updateWorkspaceMembership(cache, workspaceMember2, 1, #member);

  cache;
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
            expect.nat(ctx.roundCount).equal(0);
            expect.bool(ctx.forceTerminated).equal(false);
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
            expect.nat(ctx.roundCount).equal(0);
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
            // workspaceAdmin1 has #admin scope in workspace 0
            switch (Map.get(ctx.workspaceScopes, Nat.compare, 0)) {
              case (null) { expect.bool(false).equal(true) };
              case (?scope) { expect.bool(scope == #admin).equal(true) };
            };
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

suite(
  "SlackAuthMiddleware - withRound",
  func() {
    test(
      "should update roundCount and forceTerminated",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(primaryOwner, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let updated = SlackAuthMiddleware.withRound(ctx, 5, true);
        expect.nat(updated.roundCount).equal(5);
        expect.bool(updated.forceTerminated).equal(true);
      },
    );

    test(
      "should preserve other fields when updating rounds",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(orgAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let updated = SlackAuthMiddleware.withRound(ctx, 3, false);
        expect.text(updated.slackUserId).equal(orgAdmin1);
        expect.bool(updated.isPrimaryOwner).equal(false);
        expect.bool(updated.isOrgAdmin).equal(true);
        expect.nat(updated.roundCount).equal(3);
      },
    );
  },
);

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
      "should reject workspace member",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
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
      "should reject member when requiring admin",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
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
// Suite: authorize - IsWorkspaceMember
// ============================================

suite(
  "SlackAuthMiddleware.authorize - IsWorkspaceMember",
  func() {
    test(
      "should allow workspace member",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceMember(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow workspace admin as member",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceMember(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject non-member",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceMember1 is only a member of workspace 0
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceMember(1)]);
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
      "should pass workspace admin check when requiring admin OR member of same workspace",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceAdmin1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceAdmin1 is #admin of workspace 0, so satisfies first step
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(0), #IsWorkspaceMember(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should pass workspace member check when admin check fails but member check succeeds",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceMember1 fails #admin check for workspace 0, but passes #member check for workspace 0
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(0), #IsWorkspaceMember(0)]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should fail workspace checks when user has no access to either workspace",
      func() {
        let cache = buildTestCache();
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        // workspaceMember1 only has access to workspace 0, so both workspace 1 checks fail
        let result = SlackAuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin(1), #IsWorkspaceMember(1)]);
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
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
          case (null) { expect.bool(false).equal(true); loop {} };
          case (?c) { c };
        };

        let result = SlackAuthMiddleware.authorize(
          ctx,
          [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(0), #IsWorkspaceMember(1)],
        );
        switch (result) {
          case (#ok(_)) { expect.bool(false).equal(true) }; // should fail
          case (#err(msg)) {
            // Should consolidate role-based errors and include member error
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
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
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
        let ctx = switch (SlackAuthMiddleware.buildFromCache(workspaceMember1, cache)) {
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
