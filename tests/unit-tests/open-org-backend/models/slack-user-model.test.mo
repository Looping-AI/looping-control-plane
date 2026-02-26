import { test; suite; expect } "mo:test";
import Result "mo:core/Result";
import SlackUserModel "../../../../src/open-org-backend/models/slack-user-model";

// ============================================
// Helpers
// ============================================

func resultUnitToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok(())" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultUnitEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

func resultBoolToText(r : Result.Result<Bool, Text>) : Text {
  switch (r) {
    case (#ok b) { "#ok(" # debug_show (b) # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultBoolEqual(r1 : Result.Result<Bool, Text>, r2 : Result.Result<Bool, Text>) : Bool {
  r1 == r2;
};

// ============================================
// Suite: empty / newEntry
// ============================================

suite(
  "SlackUserModel - empty and newEntry",
  func() {
    test(
      "empty() creates a cache with no users",
      func() {
        let cache = SlackUserModel.empty();
        let users = SlackUserModel.listUsers(cache);
        expect.nat(users.size()).equal(0);
      },
    );

    test(
      "newEntry() creates an entry with the provided fields and no memberships",
      func() {
        let entry = SlackUserModel.newEntry("U001", "Alice", true, false);
        expect.text(entry.slackUserId).equal("U001");
        expect.text(entry.displayName).equal("Alice");
        expect.bool(entry.isPrimaryOwner).equal(true);
        expect.bool(entry.isOrgAdmin).equal(false);
        expect.nat(SlackUserModel.getWorkspaceMemberships(entry).size()).equal(0);
      },
    );
  },
);

// ============================================
// Suite: upsertUser / lookupUser
// ============================================

suite(
  "SlackUserModel - upsertUser and lookupUser",
  func() {
    test(
      "upsertUser inserts a new user and lookupUser retrieves it",
      func() {
        let cache = SlackUserModel.empty();
        let entry = SlackUserModel.newEntry("U001", "Alice", false, false);

        SlackUserModel.upsertUser(cache, entry);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) }; // force fail
          case (?found) {
            expect.text(found.slackUserId).equal("U001");
            expect.text(found.displayName).equal("Alice");
          };
        };
      },
    );

    test(
      "upsertUser overwrites an existing entry",
      func() {
        let cache = SlackUserModel.empty();
        let entry1 = SlackUserModel.newEntry("U001", "Alice", false, false);
        let entry2 = SlackUserModel.newEntry("U001", "Alice Renamed", false, true);

        SlackUserModel.upsertUser(cache, entry1);
        SlackUserModel.upsertUser(cache, entry2);

        let users = SlackUserModel.listUsers(cache);
        expect.nat(users.size()).equal(1);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?found) {
            expect.text(found.displayName).equal("Alice Renamed");
            expect.bool(found.isOrgAdmin).equal(true);
          };
        };
      },
    );

    test(
      "lookupUser returns null for unknown user",
      func() {
        let cache = SlackUserModel.empty();
        switch (SlackUserModel.lookupUser(cache, "U999")) {
          case (null) { expect.bool(true).equal(true) }; // expected
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "upsertUser inserts multiple distinct users",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", true, false));
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U002", "Bob", false, true));
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U003", "Carol", false, false));

        expect.nat(SlackUserModel.listUsers(cache).size()).equal(3);
      },
    );
  },
);

// ============================================
// Suite: removeUser
// ============================================

suite(
  "SlackUserModel - removeUser",
  func() {
    test(
      "removeUser removes existing user and returns true",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let removed = SlackUserModel.removeUser(cache, "U001");
        expect.bool(removed).equal(true);
        expect.nat(SlackUserModel.listUsers(cache).size()).equal(0);
      },
    );

    test(
      "removeUser returns false for unknown user",
      func() {
        let cache = SlackUserModel.empty();
        let removed = SlackUserModel.removeUser(cache, "U999");
        expect.bool(removed).equal(false);
      },
    );

    test(
      "removeUser only removes the targeted user",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U002", "Bob", false, false));

        ignore SlackUserModel.removeUser(cache, "U001");
        expect.nat(SlackUserModel.listUsers(cache).size()).equal(1);

        switch (SlackUserModel.lookupUser(cache, "U002")) {
          case (null) { expect.bool(false).equal(true) };
          case (?_) { expect.bool(true).equal(true) };
        };
      },
    );
  },
);

// ============================================
// Suite: joinAdminChannel
// ============================================

suite(
  "SlackUserModel - joinAdminChannel",
  func() {
    test(
      "sets inAdminChannel and scope becomes #admin",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.joinAdminChannel(cache, "U001", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #admin).equal(true) };
        };
      },
    );

    test(
      "does not clear inMemberChannel when joining admin channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        let result = SlackUserModel.joinAdminChannel(cache, "U001", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        // scope should be #admin (admin channel takes precedence)
        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #admin).equal(true) };
        };
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let cache = SlackUserModel.empty();
        let result = SlackUserModel.joinAdminChannel(cache, "U999", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "memberships across different workspaces are visible after re-lookup",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 2);
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 3);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let memberships = SlackUserModel.getWorkspaceMemberships(entry);
            expect.nat(memberships.size()).equal(2);
          };
        };
      },
    );
  },
);

// ============================================
// Suite: joinMemberChannel
// ============================================

suite(
  "SlackUserModel - joinMemberChannel",
  func() {
    test(
      "sets inMemberChannel and scope becomes #member",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.joinMemberChannel(cache, "U001", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #member).equal(true) };
        };
      },
    );

    test(
      "does not clear inAdminChannel when joining member channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);

        let result = SlackUserModel.joinMemberChannel(cache, "U001", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        // scope stays #admin because inAdminChannel is still set
        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #admin).equal(true) };
        };
      },
    );

    test(
      "memberships across different workspaces are visible after re-lookup",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 2);
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 3);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let memberships = SlackUserModel.getWorkspaceMemberships(entry);
            expect.nat(memberships.size()).equal(2);
          };
        };
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let cache = SlackUserModel.empty();
        let result = SlackUserModel.joinMemberChannel(cache, "U999", 1);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("User not found: U999")
        );
      },
    );
  },
);

// ============================================
// Suite: leaveAdminChannel
// ============================================

suite(
  "SlackUserModel - leaveAdminChannel",
  func() {
    test(
      "removes membership entirely when user was only in admin channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveAdminChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(true).equal(true) }; // expected — no longer in any channel
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "downgrades scope to #member when user is still in member channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveAdminChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #member).equal(true) };
        };
      },
    );

    test(
      "returns #ok(false) when inAdminChannel flag was already clear",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveAdminChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #ok(false) when workspace membership doesn't exist",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.leaveAdminChannel(cache, "U001", 99);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let cache = SlackUserModel.empty();
        let result = SlackUserModel.leaveAdminChannel(cache, "U999", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "only affects the targeted workspace",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 2);

        ignore SlackUserModel.leaveAdminChannel(cache, "U001", 1);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let memberships = SlackUserModel.getWorkspaceMemberships(entry);
            expect.nat(memberships.size()).equal(1);

            switch (SlackUserModel.getWorkspaceScope(cache, "U001", 2)) {
              case (null) { expect.bool(false).equal(true) };
              case (?s) { expect.bool(s == #member).equal(true) };
            };
          };
        };
      },
    );
  },
);

// ============================================
// Suite: leaveMemberChannel
// ============================================

suite(
  "SlackUserModel - leaveMemberChannel",
  func() {
    test(
      "removes membership entirely when user was only in member channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveMemberChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(true).equal(true) }; // expected — no longer in any channel
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "retains #admin scope when user is still in admin channel",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveMemberChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #admin).equal(true) };
        };
      },
    );

    test(
      "returns #ok(false) when inMemberChannel flag was already clear",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 1);

        let result = SlackUserModel.leaveMemberChannel(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #ok(false) when workspace membership doesn't exist",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.leaveMemberChannel(cache, "U001", 99);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let cache = SlackUserModel.empty();
        let result = SlackUserModel.leaveMemberChannel(cache, "U999", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "only affects the targeted workspace",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);
        ignore SlackUserModel.joinAdminChannel(cache, "U001", 2);

        ignore SlackUserModel.leaveMemberChannel(cache, "U001", 1);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let memberships = SlackUserModel.getWorkspaceMemberships(entry);
            expect.nat(memberships.size()).equal(1);

            switch (SlackUserModel.getWorkspaceScope(cache, "U001", 2)) {
              case (null) { expect.bool(false).equal(true) };
              case (?s) { expect.bool(s == #admin).equal(true) };
            };
          };
        };
      },
    );
  },
);

// ============================================
// Suite: getWorkspaceScope
// ============================================

suite(
  "SlackUserModel - getWorkspaceScope",
  func() {
    test(
      "returns null when user not in cache",
      func() {
        let cache = SlackUserModel.empty();
        switch (SlackUserModel.getWorkspaceScope(cache, "U999", 1)) {
          case (null) { expect.bool(true).equal(true) };
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns null when user exists but has no membership in that workspace",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 5)) {
          case (null) { expect.bool(true).equal(true) };
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns correct scope after membership is set",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.joinMemberChannel(cache, "U001", 1);

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #member).equal(true) };
        };
      },
    );
  },
);
