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
// Suite: updateWorkspaceMembership
// ============================================

suite(
  "SlackUserModel - updateWorkspaceMembership",
  func() {
    test(
      "adds a new workspace membership to an existing user",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #admin);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let scope = SlackUserModel.getWorkspaceScope(cache, "U001", 1);
        switch (scope) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #admin).equal(true) };
        };
      },
    );

    test(
      "updates an existing workspace membership",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #member);

        let result = SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #admin);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

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
        let result = SlackUserModel.updateWorkspaceMembership(cache, "U999", 1, #member);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "membership update is visible after re-lookup",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 2, #member);
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 3, #admin);

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
// Suite: removeWorkspaceMembership
// ============================================

suite(
  "SlackUserModel - removeWorkspaceMembership",
  func() {
    test(
      "removes an existing membership and returns #ok(true)",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #admin);

        let result = SlackUserModel.removeWorkspaceMembership(cache, "U001", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(true).equal(true) }; // expected — membership gone
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns #ok(false) when membership doesn't exist",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));

        let result = SlackUserModel.removeWorkspaceMembership(cache, "U001", 99);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(false));
      },
    );

    test(
      "returns #err when user not found",
      func() {
        let cache = SlackUserModel.empty();
        let result = SlackUserModel.removeWorkspaceMembership(cache, "U999", 1);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("User not found: U999")
        );
      },
    );

    test(
      "only removes the targeted membership",
      func() {
        let cache = SlackUserModel.empty();
        SlackUserModel.upsertUser(cache, SlackUserModel.newEntry("U001", "Alice", false, false));
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #admin);
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 2, #member);

        ignore SlackUserModel.removeWorkspaceMembership(cache, "U001", 1);

        switch (SlackUserModel.lookupUser(cache, "U001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?entry) {
            let memberships = SlackUserModel.getWorkspaceMemberships(entry);
            expect.nat(memberships.size()).equal(1);

            // Workspace 2 should still exist
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
        ignore SlackUserModel.updateWorkspaceMembership(cache, "U001", 1, #member);

        switch (SlackUserModel.getWorkspaceScope(cache, "U001", 1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?s) { expect.bool(s == #member).equal(true) };
        };
      },
    );
  },
);
