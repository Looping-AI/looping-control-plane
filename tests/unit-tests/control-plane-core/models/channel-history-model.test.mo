import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import ChannelHistoryModel "../../../../src/control-plane-core/models/channel-history-model";
import SlackAuthMiddleware "../../../../src/control-plane-core/middleware/slack-auth-middleware";
import SlackUserModel "../../../../src/control-plane-core/models/slack-user-model";

// ── helpers ──────────────────────────────────────────────────────────────────

/// Build a ChannelMessage with no user context (agent/bot message).
func agentMsg(ts : Text, text : Text) : ChannelHistoryModel.ChannelMessage {
  { ts; userAuthContext = null; text; agentMetadata = null };
};

func isSome<A>(x : ?A) : Bool { switch x { case null false; case _ true } };
func isNone<A>(x : ?A) : Bool { switch x { case null true; case _ false } };

/// Build a minimal UserAuthContext for round-context tests.
func makeRoundCtx(userId : Text, roundCount : Nat, forceTerminated : Bool) : SlackAuthMiddleware.UserAuthContext {
  {
    slackUserId = userId;
    isPrimaryOwner = false;
    isOrgAdmin = false;
    adminWorkspaces = Map.empty<Nat, ()>();
    roundCount;
    forceTerminated;
    parentRef = null;
  };
};

// ── empty ─────────────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - empty",
  func() {
    test(
      "returns an empty ChannelHistoryStore",
      func() {
        let store = ChannelHistoryModel.empty();
        let entries = ChannelHistoryModel.getRecentEntries(store, "C001", 10);
        expect.nat(entries.size()).equal(0);
      },
    );
  },
);

// ── addMessage / getEntry ─────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - addMessage top-level",
  func() {
    test(
      "stores a top-level message as #post",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Hello"), null);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
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
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "First"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "Second"), null);

        expect.bool(isSome(ChannelHistoryModel.getEntry(store, "C001", "1000.000001"))).equal(true);
        expect.bool(isSome(ChannelHistoryModel.getEntry(store, "C001", "1001.000001"))).equal(true);
      },
    );

    test(
      "keeps separate entries per channel",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "chan1"), null);
        ChannelHistoryModel.addMessage(store, "C002", agentMsg("1000.000001", "chan2"), null);

        let e1 = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        let e2 = ChannelHistoryModel.getEntry(store, "C002", "1000.000001");
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
  "ChannelHistoryModel - addMessage thread reply",
  func() {
    test(
      "first reply promotes #post to #thread",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
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
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply 1"), ?"1000.000001");
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000003", "Reply 2"), ?"1000.000001");

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(3) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "creates sparse #thread when reply arrives before root",
      func() {
        let store = ChannelHistoryModel.empty();
        // No root added — reply arrives first
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
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
        let store = ChannelHistoryModel.empty();
        // Two replies arrive before the root.
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply 1"), ?"1000.000001");
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000003", "Reply 2"), ?"1000.000001");
        // Root message arrives later as a top-level post.
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
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
  "ChannelHistoryModel - getEntry",
  func() {
    test(
      "returns null for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.getEntry(store, "CNONE", "1000.000001");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "returns null for unknown ts in known channel",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ChannelHistoryModel.getEntry(store, "C001", "9999.999999");
        expect.bool(isNone(result)).equal(true);
      },
    );
  },
);

// ── getRecentEntries ──────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - getRecentEntries",
  func() {
    test(
      "returns empty array for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.getRecentEntries(store, "CNONE", 5);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns all entries when count <= limit",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "A"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "B"), null);

        let result = ChannelHistoryModel.getRecentEntries(store, "C001", 10);
        expect.nat(result.size()).equal(2);
      },
    );

    test(
      "returns only the last N entries when count > limit",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "A"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "B"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1002.000001", "C"), null);

        let result = ChannelHistoryModel.getRecentEntries(store, "C001", 2);
        expect.nat(result.size()).equal(2);
        expect.text(result[0].ts).equal("1001.000001");
        expect.text(result[1].ts).equal("1002.000001");
      },
    );

    test(
      "hasReplies is false for a #post entry",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root only"), null);

        let result = ChannelHistoryModel.getRecentEntries(store, "C001", 5);
        expect.bool(result[0].hasReplies).equal(false);
      },
    );

    test(
      "hasReplies is true when a reply exists (#thread)",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let result = ChannelHistoryModel.getRecentEntries(store, "C001", 5);
        expect.bool(result[0].hasReplies).equal(true);
      },
    );
  },
);

// ── updateMessageText ─────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - updateMessageText",
  func() {
    test(
      "updates a #post message and returns true",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Original"), null);

        let updated = ChannelHistoryModel.updateMessageText(store, "C001", "1000.000001", "1000.000001", "Edited");
        expect.bool(updated).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#post msg) { expect.text(msg.text).equal("Edited") };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates a message inside a #thread and returns true",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let updated = ChannelHistoryModel.updateMessageText(store, "C001", "1000.000001", "1000.000002", "Edited reply");
        expect.bool(updated).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
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
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.updateMessageText(store, "CNONE", "1000.000001", "1000.000001", "X");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false when ts does not match any message",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ChannelHistoryModel.updateMessageText(store, "C001", "1000.000001", "9999.000001", "X");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── deleteMessage ─────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - deleteMessage",
  func() {
    test(
      "removes a reply from a #thread and returns true",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let deleted = ChannelHistoryModel.deleteMessage(store, "C001", "1000.000001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(1) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "removes a #post entry from the timeline",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Only"), null);

        let deleted = ChannelHistoryModel.deleteMessage(store, "C001", "1000.000001", "1000.000001");
        expect.bool(deleted).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "drops a #thread entry when all messages are removed",
      func() {
        let store = ChannelHistoryModel.empty();
        // Sparse thread — reply arrived before root, only one message
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");

        let deleted = ChannelHistoryModel.deleteMessage(store, "C001", "1000.000001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "returns false when channel does not exist",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.deleteMessage(store, "CNONE", "1000.000001", "1000.000001");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false when ts is not found",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ChannelHistoryModel.deleteMessage(store, "C001", "1000.000001", "9999.999999");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── findAndDeleteMessage ──────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - findAndDeleteMessage",
  func() {
    test(
      "finds and deletes a reply via replyIndex",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let deleted = ChannelHistoryModel.findAndDeleteMessage(store, "C001", "1000.000002");
        expect.bool(deleted).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        switch (entry) {
          case (?#thread t) { expect.nat(Map.size(t.messages)).equal(1) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "finds and deletes a #post by its root ts",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Only"), null);

        let deleted = ChannelHistoryModel.findAndDeleteMessage(store, "C001", "1000.000001");
        expect.bool(deleted).equal(true);

        let entry = ChannelHistoryModel.getEntry(store, "C001", "1000.000001");
        expect.bool(isNone(entry)).equal(true);
      },
    );

    test(
      "returns false when ts is not found anywhere",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ChannelHistoryModel.findAndDeleteMessage(store, "C001", "9999.999999");
        expect.bool(result).equal(false);
      },
    );

    test(
      "returns false for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.findAndDeleteMessage(store, "CNONE", "1000.000001");
        expect.bool(result).equal(false);
      },
    );
  },
);

// ── pruneChannel ──────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - pruneChannel",
  func() {
    test(
      "removes a #post entry older than cutoff",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("500.000001", "Old"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("2000.000001", "New"), null);

        // Prune with cutoff = 1000 — anything < 1000 is stale
        ChannelHistoryModel.pruneChannel(store, "C001", 1000);

        expect.bool(isNone(ChannelHistoryModel.getEntry(store, "C001", "500.000001"))).equal(true);
        expect.bool(isSome(ChannelHistoryModel.getEntry(store, "C001", "2000.000001"))).equal(true);
      },
    );

    test(
      "applies old-thread grace rule: keeps #thread with any recent reply",
      func() {
        let store = ChannelHistoryModel.empty();
        // Root is old (ts 500)
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("500.000001", "Old root"), null);
        // But it has a recent reply (ts 2000) → promotes to #thread
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("2000.000001", "Recent reply"), ?"500.000001");

        ChannelHistoryModel.pruneChannel(store, "C001", 1000);

        expect.bool(isSome(ChannelHistoryModel.getEntry(store, "C001", "500.000001"))).equal(true);
      },
    );

    test(
      "is a no-op for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        // Should not throw
        ChannelHistoryModel.pruneChannel(store, "CNONE", 1000);
        expect.bool(true).equal(true);
      },
    );
  },
);

// ── pruneAll ──────────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - pruneAll",
  func() {
    test(
      "prunes across multiple channels",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("500.000001", "Old C1"), null);
        ChannelHistoryModel.addMessage(store, "C002", agentMsg("500.000001", "Old C2"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("2000.000001", "New C1"), null);

        ChannelHistoryModel.pruneAll(store, 1000);

        expect.bool(isNone(ChannelHistoryModel.getEntry(store, "C001", "500.000001"))).equal(true);
        expect.bool(isNone(ChannelHistoryModel.getEntry(store, "C002", "500.000001"))).equal(true);
        expect.bool(isSome(ChannelHistoryModel.getEntry(store, "C001", "2000.000001"))).equal(true);
      },
    );
  },
);

// ── getMessage ────────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - getMessage",
  func() {
    test(
      "returns null for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.getMessage(store, "C001", "1000.000001");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "returns null for unknown ts in known channel",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Hello"), null);
        let result = ChannelHistoryModel.getMessage(store, "C001", "9999.000000");
        expect.bool(isNone(result)).equal(true);
      },
    );

    test(
      "finds a top-level message by ts",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        switch (ChannelHistoryModel.getMessage(store, "C001", "1000.000001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Root") };
        };
      },
    );

    test(
      "finds a reply message via replyIndex",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");
        switch (ChannelHistoryModel.getMessage(store, "C001", "1000.000002")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Reply") };
        };
      },
    );

    test(
      "root message is still accessible after replies are added",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");
        switch (ChannelHistoryModel.getMessage(store, "C001", "1000.000001")) {
          case (null) { expect.bool(false).equal(true) };
          case (?msg) { expect.text(msg.text).equal("Root") };
        };
      },
    );

    test(
      "messages in different channels are independent",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "In C001"), null);
        ChannelHistoryModel.addMessage(store, "C002", agentMsg("1000.000001", "In C002"), null);
        switch (ChannelHistoryModel.getMessage(store, "C001", "1000.000001")) {
          case (?msg) { expect.text(msg.text).equal("In C001") };
          case (null) { expect.bool(false).equal(true) };
        };
        switch (ChannelHistoryModel.getMessage(store, "C002", "1000.000001")) {
          case (?msg) { expect.text(msg.text).equal("In C002") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

// ── getRecentRootMessages ─────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - getRecentRootMessages",
  func() {
    test(
      "returns empty array for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.getRecentRootMessages(store, "CNONE", 10);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns root messages from #post entries",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "First"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "Second"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1002.000001", "Third"), null);

        let result = ChannelHistoryModel.getRecentRootMessages(store, "C001", 10);
        expect.nat(result.size()).equal(3);
        expect.text(result[0].text).equal("First");
        expect.text(result[1].text).equal("Second");
        expect.text(result[2].text).equal("Third");
      },
    );

    test(
      "returns only the last N root messages when count > limit",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "A"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "B"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1002.000001", "C"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1003.000001", "D"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1004.000001", "E"), null);

        let result = ChannelHistoryModel.getRecentRootMessages(store, "C001", 3);
        expect.nat(result.size()).equal(3);
        expect.text(result[0].text).equal("C");
        expect.text(result[1].text).equal("D");
        expect.text(result[2].text).equal("E");
      },
    );

    test(
      "returns root message of #thread entries",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");

        let result = ChannelHistoryModel.getRecentRootMessages(store, "C001", 10);
        expect.nat(result.size()).equal(1);
        expect.text(result[0].text).equal("Root");
        expect.text(result[0].ts).equal("1000.000001");
      },
    );

    test(
      "skips sparse threads with no root message",
      func() {
        let store = ChannelHistoryModel.empty();
        // Reply arrives with no root — creates sparse thread
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");
        // Also add a normal post
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1001.000001", "Normal"), null);

        let result = ChannelHistoryModel.getRecentRootMessages(store, "C001", 10);
        // Sparse thread has no root message at rootTs, so it's skipped
        expect.nat(result.size()).equal(1);
        expect.text(result[0].text).equal("Normal");
      },
    );
  },
);

// ── getRecentThreadMessages ──────────────────────────────────────────────────────────────────────────────

suite(
  "ChannelHistoryModel - getRecentThreadMessages",
  func() {
    test(
      "returns empty array for unknown channel",
      func() {
        let store = ChannelHistoryModel.empty();
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "CNONE", "1000.000001", 10);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns empty array for unknown rootTs",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Msg"), null);
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "C001", "9999.000001", 10);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns empty array for a #post entry",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Standalone"), null);
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "C001", "1000.000001", 10);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "returns messages from a sparse thread (reply arrived before root)",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "C001", "1000.000001", 10);
        expect.nat(result.size()).equal(1);
        expect.text(result[0].text).equal("Orphan reply");
      },
    );

    test(
      "returns root + reply for a normal two-message thread",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "Reply"), ?"1000.000001");
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "C001", "1000.000001", 10);
        expect.nat(result.size()).equal(2);
        expect.text(result[0].text).equal("Root");
        expect.text(result[1].text).equal("Reply");
      },
    );

    test(
      "returns only the last N messages when thread is larger than limit",
      func() {
        let store = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000001", "Root"), null);
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000002", "R1"), ?"1000.000001");
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000003", "R2"), ?"1000.000001");
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000004", "R3"), ?"1000.000001");
        ChannelHistoryModel.addMessage(store, "C001", agentMsg("1000.000005", "R4"), ?"1000.000001");
        let result = ChannelHistoryModel.getRecentThreadMessages(store, "C001", "1000.000001", 3);
        expect.nat(result.size()).equal(3);
        expect.text(result[0].text).equal("R2");
        expect.text(result[1].text).equal("R3");
        expect.text(result[2].text).equal("R4");
      },
    );
  },
);
