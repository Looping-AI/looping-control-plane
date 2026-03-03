import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import ConversationModel "../../../../src/open-org-backend/models/conversation-model";
import SlackAuthMiddleware "../../../../src/open-org-backend/middleware/slack-auth-middleware";
import SlackUserModel "../../../../src/open-org-backend/models/slack-user-model";

// ── helpers ──────────────────────────────────────────────────────────────────

/// Build a ConversationMessage with no user context (agent/bot message).
func agentMsg(ts : Text, text : Text) : ConversationModel.ConversationMessage {
  { ts; userAuthContext = null; text };
};

func isSome<A>(x : ?A) : Bool { switch x { case null false; case _ true } };
func isNone<A>(x : ?A) : Bool { switch x { case null true; case _ false } };

/// Build a minimal UserAuthContext for round-context tests.
func makeRoundCtx(userId : Text, roundCount : Nat, forceTerminated : Bool) : SlackAuthMiddleware.UserAuthContext {
  {
    slackUserId = userId;
    isPrimaryOwner = false;
    isOrgAdmin = false;
    workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    roundCount;
    forceTerminated;
    parentRef = null;
  };
};

// ── empty ─────────────────────────────────────────────────────────────────────

suite(
  "ConversationModel - empty",
  func() {
    test(
      "returns an empty ConversationStore",
      func() {
        let store = ConversationModel.empty();
        let entries = ConversationModel.getRecentEntries(store, "C001", 10);
        expect.nat(entries.size()).equal(0);
      },
    );
  },
);

// ── addMessage / getEntry ─────────────────────────────────────────────────────

suite(
  "ConversationModel - addMessage top-level",
  func() {
    test(
      "stores a top-level message as #post",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Hello"), null);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (null) { expect.bool(false).equal(true) };
          case (?#post msg) {
            expect.text(msg.ts).equal("1000.000001");
            expect.text(msg.text).equal("Hello");
          };
          case (?#thread _) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "creates independent #post entries for different top-level messages",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "First"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1001.000001", "Second"), null);

        expect.bool(isSome(ConversationModel.getEntry(store, "C001", "1000.000001"))).equal(true);
        expect.bool(isSome(ConversationModel.getEntry(store, "C001", "1001.000001"))).equal(true);
      },
    );

    test(
      "keeps separate entries per channel",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "chan1"), null);
        ConversationModel.addMessage(store, "C002", agentMsg("1000.000001", "chan2"), null);

        let e1 = ConversationModel.getEntry(store, "C001", "1000.000001");
        let e2 = ConversationModel.getEntry(store, "C002", "1000.000001");
        switch (e1) {
          case (?#post msg) { expect.text(msg.text).equal("chan1") };
          case (_) { expect.bool(false).equal(true) };
        };
        switch (e2) {
          case (?#post msg) { expect.text(msg.text).equal("chan2") };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "ConversationModel - addMessage thread reply",
  func() {
    test(
      "first reply promotes #post to #thread",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) {
            expect.text(t.rootTs).equal("1000.000001");
            expect.nat(Map.size(t.messages)).equal(2);
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "subsequent replies are appended to existing #thread",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply 1"), ?"1000.000001");
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000003", "Reply 2"), ?"1000.000001");

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(3) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "creates sparse #thread when reply arrives before root",
      func() {
        let store = ConversationModel.empty();
        // No root added — reply arrives first
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) {
            expect.text(t.rootTs).equal("1000.000001");
            expect.nat(Map.size(t.messages)).equal(1);
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "root arriving after replies merges into existing #thread without dropping replies",
      func() {
        let store = ConversationModel.empty();
        // Two replies arrive before the root.
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply 1"), ?"1000.000001");
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000003", "Reply 2"), ?"1000.000001");
        // Root message arrives later as a top-level post.
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) {
            // Still a thread (not downgraded to #post).
            expect.text(t.rootTs).equal("1000.000001");
            // Root + two replies must all be present.
            expect.nat(Map.size(t.messages)).equal(3);
            // Verify the root message text is accessible.
            switch (Map.get(t.messages, Text.compare, "1000.000001")) {
              case (?msg) { expect.text(msg.text).equal("Root") };
              case (null) { expect.bool(false).equal(true) };
            };
            // Verify replies were not dropped.
            expect.bool(isSome(Map.get(t.messages, Text.compare, "1000.000002"))).equal(true);
            expect.bool(isSome(Map.get(t.messages, Text.compare, "1000.000003"))).equal(true);
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

// ── getEntry ──────────────────────────────────────────────────────────────────

suite(
  "ConversationModel - getEntry",
  func() {
    test(
      "returns null for unknown channel",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.getEntry(store, "CNONE", "1000.000001");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "returns null for unknown ts in known channel",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ConversationModel.getEntry(store, "C001", "9999.999999");
        expect.bool(isNone(result)).equal(true);
      },
    );
  },
);

// ── getRecentEntries ──────────────────────────────────────────────────────────

suite(
  "ConversationModel - getRecentEntries",
  func() {
    test(
      "returns empty array for unknown channel",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.getRecentEntries(store, "CNONE", 5);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns all entries when count <= limit",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "A"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1001.000001", "B"), null);

        let result = ConversationModel.getRecentEntries(store, "C001", 10);
        expect.nat(result.size()).equal(2);
      },
    );

    test(
      "returns only the last N entries when count > limit",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "A"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1001.000001", "B"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1002.000001", "C"), null);

        let result = ConversationModel.getRecentEntries(store, "C001", 2);
        expect.nat(result.size()).equal(2);
        expect.text(result[0].ts).equal("1001.000001");
        expect.text(result[1].ts).equal("1002.000001");
      },
    );

    test(
      "hasReplies is false for a #post entry",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root only"), null);

        let result = ConversationModel.getRecentEntries(store, "C001", 5);
        expect.bool(result[0].hasReplies).equal(false);
      },
    );

    test(
      "hasReplies is true when a reply exists (#thread)",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let result = ConversationModel.getRecentEntries(store, "C001", 5);
        expect.bool(result[0].hasReplies).equal(true);
      },
    );
  },
);

// ── updateMessageText ─────────────────────────────────────────────────────────

suite(
  "ConversationModel - updateMessageText",
  func() {
    test(
      "updates a #post message and returns true",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Original"), null);

        let updated = ConversationModel.updateMessageText(store, "C001", "1000.000001", "1000.000001", "Edited");
        expect.bool(updated).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#post msg) { expect.text(msg.text).equal("Edited") };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates a message inside a #thread and returns true",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let updated = ConversationModel.updateMessageText(store, "C001", "1000.000001", "1000.000002", "Edited reply");
        expect.bool(updated).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) {
            switch (Map.get(t.messages, Text.compare, "1000.000002")) {
              case (?msg) { expect.text(msg.text).equal("Edited reply") };
              case (null) { expect.bool(false).equal(true) };
            };
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns false when channel does not exist",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.updateMessageText(store, "CNONE", "1000.000001", "1000.000001", "X");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false when ts does not match any message",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ConversationModel.updateMessageText(store, "C001", "1000.000001", "9999.000001", "X");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── deleteMessage ─────────────────────────────────────────────────────────────

suite(
  "ConversationModel - deleteMessage",
  func() {
    test(
      "removes a reply from a #thread and returns true",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let deleted = ConversationModel.deleteMessage(store, "C001", "1000.000001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(1) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "removes a #post entry from the timeline",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Only"), null);

        let deleted = ConversationModel.deleteMessage(store, "C001", "1000.000001", "1000.000001");
        expect.bool(deleted).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "drops a #thread entry when all messages are removed",
      func() {
        let store = ConversationModel.empty();
        // Sparse thread — reply arrived before root, only one message
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");

        let deleted = ConversationModel.deleteMessage(store, "C001", "1000.000001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "returns false when channel does not exist",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.deleteMessage(store, "CNONE", "1000.000001", "1000.000001");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false when ts is not found",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ConversationModel.deleteMessage(store, "C001", "1000.000001", "9999.999999");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── findAndDeleteMessage ──────────────────────────────────────────────────────

suite(
  "ConversationModel - findAndDeleteMessage",
  func() {
    test(
      "finds and deletes a reply via replyIndex",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let deleted = ConversationModel.findAndDeleteMessage(store, "C001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(1) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "finds and deletes a #post by its root ts",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Only"), null);

        let deleted = ConversationModel.findAndDeleteMessage(store, "C001", "1000.000001");
        expect.bool(deleted).equal(true);

        let entry = ConversationModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "returns false when ts is not found anywhere",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ConversationModel.findAndDeleteMessage(store, "C001", "9999.999999");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false for unknown channel",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.findAndDeleteMessage(store, "CNONE", "1000.000001");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── pruneChannel ──────────────────────────────────────────────────────────────

suite(
  "ConversationModel - pruneChannel",
  func() {
    test(
      "removes a #post entry older than cutoff",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("500.000001", "Old"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("2000.000001", "New"), null);

        // Prune with cutoff = 1000 — anything < 1000 is stale
        ConversationModel.pruneChannel(store, "C001", 1000);

        expect.bool(isNone(ConversationModel.getEntry(store, "C001", "500.000001"))).equal(true);
        expect.bool(isSome(ConversationModel.getEntry(store, "C001", "2000.000001"))).equal(true);
      },
    );

    test(
      "applies old-thread grace rule: keeps #thread with any recent reply",
      func() {
        let store = ConversationModel.empty();
        // Root is old (ts 500)
        ConversationModel.addMessage(store, "C001", agentMsg("500.000001", "Old root"), null);
        // But it has a recent reply (ts 2000) → promotes to #thread
        ConversationModel.addMessage(store, "C001", agentMsg("2000.000001", "Recent reply"), ?"500.000001");

        ConversationModel.pruneChannel(store, "C001", 1000);

        expect.bool(isSome(ConversationModel.getEntry(store, "C001", "500.000001"))).equal(true);
      },
    );

    test(
      "is a no-op for unknown channel",
      func() {
        let store = ConversationModel.empty();
        // Should not throw
        ConversationModel.pruneChannel(store, "CNONE", 1000);
        expect.bool(true).equal(true);
      },
    );
  },
);

// ── pruneAll ──────────────────────────────────────────────────────────────────

suite(
  "ConversationModel - pruneAll",
  func() {
    test(
      "prunes across multiple channels",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("500.000001", "Old C1"), null);
        ConversationModel.addMessage(store, "C002", agentMsg("500.000001", "Old C2"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("2000.000001", "New C1"), null);

        ConversationModel.pruneAll(store, 1000);

        expect.bool(isNone(ConversationModel.getEntry(store, "C001", "500.000001"))).equal(true);
        expect.bool(isNone(ConversationModel.getEntry(store, "C002", "500.000001"))).equal(true);
        expect.bool(isSome(ConversationModel.getEntry(store, "C001", "2000.000001"))).equal(true);
      },
    );
  },
);

// ── getMessage ────────────────────────────────────────────────────────────────

suite(
  "ConversationModel - getMessage",
  func() {
    test(
      "returns null for unknown channel",
      func() {
        let store = ConversationModel.empty();
        let result = ConversationModel.getMessage(store, "C001", "1000.000001");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "returns null for unknown ts in known channel",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Hello"), null);
        let result = ConversationModel.getMessage(store, "C001", "9999.000000");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "finds a top-level message by ts",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        switch (ConversationModel.getMessage(store, "C001", "1000.000001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Root") };
        };
      },
    );

    test(
      "finds a reply message via replyIndex",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");
        switch (ConversationModel.getMessage(store, "C001", "1000.000002")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Reply") };
        };
      },
    );

    test(
      "root message is still accessible after replies are added",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");
        switch (ConversationModel.getMessage(store, "C001", "1000.000001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Root") };
        };
      },
    );

    test(
      "messages in different channels are independent",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", agentMsg("1000.000001", "In C001"), null);
        ConversationModel.addMessage(store, "C002", agentMsg("1000.000001", "In C002"), null);
        switch (ConversationModel.getMessage(store, "C001", "1000.000001")) {
          case (?msg) { expect.text(msg.text).equal("In C001") };
          case (null) { expect.bool(false).equal(true) };
        };
        switch (ConversationModel.getMessage(store, "C002", "1000.000001")) {
          case (?msg) { expect.text(msg.text).equal("In C002") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);
