import { test; suite; expect } "mo:test";
import Result "mo:core/Result";
import SlackUserModel "../../../../src/control-plane-core/models/slack-user-model";

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
        let state = SlackUserModel.emptyState();
        let users = SlackUserModel.listUsers(state.cache);
        expect.nat(users.size()).equal(0);
      },
    );

    test(
      "newEntry() creates an entry with the provided fields and no memberships",
      func() {
        let entry = SlackUserModel.newEntry("U001", "Alice", true, false, false);
        expect.text(entry.slackUserId).equal("U001");
        expect.text(entry.displayName).equal("Alice");
        expect.bool(entry.isPrimaryOwner).equal(true);
        expect.bool(entry.isOrgAdmin).equal(false);
        expect.nat(SlackUserModel.getAdminWorkspaceIds(entry).size()).equal(0);
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
        let state = SlackUserModel.emptyState();
        let entry = SlackUserModel.newEntry("U001", "Alice", false, false, false);

        SlackUserModel.upsertUser(state, entry, #manual);

        switch (SlackUserModel.lookupUser(state.cache, "U001")) {
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
        let state = SlackUserModel.emptyState();
        let entry1 = SlackUserModel.newEntry("U001", "Alice", false, false, false);
        let entry2 = SlackUserModel.newEntry("U001", "Alice Renamed", false, true, false);

        SlackUserModel.upsertUser(state, entry1, #manual);
        SlackUserModel.upsertUser(state, entry2, #manual);

        let users = SlackUserModel.listUsers(state.cache);
        expect.nat(users.size()).equal(1);

        switch (SlackUserModel.lookupUser(state.cache, "U001")) {
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
        let state = SlackUserModel.emptyState();
        switch (SlackUserModel.lookupUser(state.cache, "U999")) {
          case (null) { expect.bool(true).equal(true) }; // expected
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "upsertUser inserts multiple distinct users",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", true, false, false), #manual);
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U002", "Bob", false, true, false), #manual);
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U003", "Carol", false, false, false), #manual);

        expect.nat(SlackUserModel.listUsers(state.cache).size()).equal(3);
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
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);

        let removed = SlackUserModel.removeUser(state, "U001", #manual);
        expect.bool(removed).equal(true);
        expect.nat(SlackUserModel.listUsers(state.cache).size()).equal(0);
      },
    );

    test(
      "removeUser returns false for unknown user",
      func() {
        let state = SlackUserModel.emptyState();
        let removed = SlackUserModel.removeUser(state, "U999", #manual);
        expect.bool(removed).equal(false);
      },
    );

    test(
      "removeUser only removes the targeted user",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U002", "Bob", false, false, false), #manual);

        ignore SlackUserModel.removeUser(state, "U001", #manual);
        expect.nat(SlackUserModel.listUsers(state.cache).size()).equal(1);

        switch (SlackUserModel.lookupUser(state.cache, "U002")) {
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
      "sets admin membership for workspace",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);

        let result = SlackUserModel.joinAdminChannel(state, "U001", 1, #manual);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U001", 1)).equal(true);
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let state = SlackUserModel.emptyState();
        let result = SlackUserModel.joinAdminChannel(state, "U999", 1, #manual);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "memberships across different workspaces are visible after re-lookup",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 2, #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 3, #manual);

        switch (SlackUserModel.lookupUser(state.cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
            expect.nat(adminIds.size()).equal(2);
          };
        };
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
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 1, #manual);

        let result = SlackUserModel.leaveAdminChannel(state, "U001", 1, #manual);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U001", 1)).equal(false);
      },
    );

    test(
      "removes the membership entry entirely when leaving admin channel",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 1, #manual);

        let result = SlackUserModel.leaveAdminChannel(state, "U001", 1, #manual);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.lookupUser(state.cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
            expect.nat(adminIds.size()).equal(0);
          };
        };
      },
    );

    test(
      "returns #ok(false) when workspace membership doesn't exist",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);

        let result = SlackUserModel.leaveAdminChannel(state, "U001", 99, #manual);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let state = SlackUserModel.emptyState();
        let result = SlackUserModel.leaveAdminChannel(state, "U999", 1, #manual);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "only affects the targeted workspace",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 1, #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 2, #manual);

        ignore SlackUserModel.leaveAdminChannel(state, "U001", 1, #manual);

        switch (SlackUserModel.lookupUser(state.cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
            expect.nat(adminIds.size()).equal(1);

            expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U001", 2)).equal(true);
          };
        };
      },
    );
  },
);

// ============================================
// Suite: isWorkspaceAdmin
// ============================================

suite(
  "SlackUserModel - isWorkspaceAdmin",
  func() {
    test(
      "returns false when user not in cache",
      func() {
        let state = SlackUserModel.emptyState();
        expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U999", 1)).equal(false);
      },
    );

    test(
      "returns false when user exists but has no membership in that workspace",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U001", 5)).equal(false);
      },
    );

    test(
      "returns true after admin membership is set",
      func() {
        let state = SlackUserModel.emptyState();
        SlackUserModel.upsertUser(state, SlackUserModel.newEntry("U001", "Alice", false, false, false), #manual);
        ignore SlackUserModel.joinAdminChannel(state, "U001", 1, #manual);

        expect.bool(SlackUserModel.isWorkspaceAdmin(state.cache, "U001", 1)).equal(true);
      },
    );
  },
);
