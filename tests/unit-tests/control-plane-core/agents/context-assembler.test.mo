import { test; suite; expect } "mo:test";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Time "mo:core/Time";
import ContextAssembler "../../../../src/control-plane-core/agents/context-assembler";
import ChannelHistoryModel "../../../../src/control-plane-core/models/channel-history-model";
import Constants "../../../../src/control-plane-core/constants";
import SessionModel "../../../../src/control-plane-core/models/session-model";
import SlackUserModel "../../../../src/control-plane-core/models/slack-user-model";

// ── helpers ──────────────────────────────────────────────────────────────────

func agentMsg(ts : Text, text : Text) : ChannelHistoryModel.ChannelMessage {
  { ts; userAuthContext = null; text; agentMetadata = null };
};

func userMsg(ts : Text, text : Text) : ChannelHistoryModel.ChannelMessage {
  {
    ts;
    userAuthContext = ?{
      slackUserId = "U_TEST";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Map.empty<Nat, ()>();
    };
    text;
    agentMetadata = null;
  };
};

// ── assemble – empty state ────────────────────────────────────────────────────

suite(
  "ContextAssembler - assemble empty state",
  func() {
    test(
      "returns empty messages when everything is empty",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();

        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", null);

        expect.nat(result.messages.size()).equal(0);
        expect.nat(result.stats.summaryTokens).equal(0);
        expect.nat(result.stats.rawTurnsIncluded).equal(0);
        expect.nat(result.stats.channelSnippets).equal(0);
      },
    );
  },
);

// ── assemble – channel history only ───────────────────────────────────────────

suite(
  "ContextAssembler - channel history",
  func() {
    test(
      "includes channel root messages as user/assistant",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(chStore, "C001", userMsg("1000.000001", "Hello"), null);
        ChannelHistoryModel.addMessage(chStore, "C001", agentMsg("1001.000001", "Hi there"), null);

        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", null);

        // 1 developer separator + 2 content messages = 3
        expect.nat(result.messages.size()).equal(3);
        // First message is the channel separator (developer role)
        expect.bool(result.messages[0].role == #developer).equal(true);
        // Second is user message
        expect.bool(result.messages[1].role == #user).equal(true);
        expect.text(result.messages[1].content).equal("Hello");
        // Third is assistant message
        expect.bool(result.messages[2].role == #assistant).equal(true);
        expect.text(result.messages[2].content).equal("Hi there");
        expect.nat(result.stats.channelSnippets).equal(2);
      },
    );
  },
);

// ── assemble – thread history ─────────────────────────────────────────────────

suite(
  "ContextAssembler - thread history",
  func() {
    test(
      "includes both channel and thread messages when threadTs is set",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();
        // Channel root message
        ChannelHistoryModel.addMessage(chStore, "C001", userMsg("1000.000001", "Root question"), null);
        // Thread reply
        ChannelHistoryModel.addMessage(chStore, "C001", agentMsg("1000.000002", "Thread reply"), ?"1000.000001");

        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", ?"1000.000001");

        // Channel section: 1 separator + 1 root msg = 2
        // Thread section: 1 separator + 2 thread msgs (root + reply) = 3
        // Total = 5
        expect.nat(result.messages.size()).equal(5);
        // channelSnippets counts channel + thread messages
        expect.nat(result.stats.channelSnippets).equal(3);
      },
    );

    test(
      "returns no thread section when threadTs is null",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(chStore, "C001", userMsg("1000.000001", "Msg"), null);

        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", null);

        // Just channel separator + 1 msg = 2
        expect.nat(result.messages.size()).equal(2);
      },
    );

    test(
      "includes sparse thread messages when root never arrived",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();
        // Reply arrives but root never does — sparse thread, size = 1
        ChannelHistoryModel.addMessage(chStore, "C001", agentMsg("1000.000002", "Orphan reply"), ?"1000.000001");

        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", ?"1000.000001");

        // Sparse thread has 1 reply — thread section included, no root message in channel snippets
        expect.nat(result.messages.size()).equal(2); // thread_header + reply
        expect.nat(result.stats.channelSnippets).equal(1);
      },
    );
  },
);

// ── assemble – session memory ─────────────────────────────────────────────────

suite(
  "ContextAssembler - session memory",
  func() {
    test(
      "empty session produces no session context messages",
      func() {
        let stores = SessionModel.emptyStores();
        ignore SessionModel.getOrCreateSession(stores, 1);

        let chStore = ChannelHistoryModel.empty();
        let result = ContextAssembler.assemble(stores, 1, "1_0", chStore, "C001", null);

        expect.nat(result.messages.size()).equal(0);
        expect.nat(result.stats.summaryTokens).equal(0);
      },
    );
  },
);

// ── assemble – turn digests ───────────────────────────────────────────────────

suite(
  "ContextAssembler - turn digests",
  func() {
    test(
      "includes completed turns in session context",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();

        let turn1 = SessionModel.createTurn(stores, 1, null, null, null);
        SessionModel.appendTrace(
          stores,
          turn1.turnId,
          #llmCall({
            model = "test";
            durationMs = 100;
            finishReason = "stop";
            content = ?"Turn 1 response text";
            truncatedContent = ?"Turn 1 response text";
            thinking = null;
            toolRequests = null;
            cost = {
              promptTokens = 10;
              completionTokens = 5;
              estimatedMicroUnits = 100;
            };
          }),
        );
        SessionModel.completeTurn(stores, turn1.turnId, #succeeded, null, null);

        // Create the "current" turn (should be excluded from digests)
        let currentTurn = SessionModel.createTurn(stores, 1, null, null, null);

        let result = ContextAssembler.assemble(stores, 1, currentTurn.turnId, chStore, "C001", null);

        // Should have 1 developer message with session JSON
        expect.nat(result.messages.size()).equal(1);
        expect.bool(result.messages[0].role == #developer).equal(true);
        expect.nat(result.stats.rawTurnsIncluded).equal(1);

        // Content should contain turn digest JSON
        let hasContent = Text.contains(result.messages[0].content, #text "turn_activity");
        expect.bool(hasContent).equal(true);
      },
    );

    test(
      "excludes running turns from digests",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();

        // Create a running turn (not completed)
        ignore SessionModel.createTurn(stores, 1, null, null, null);

        // Create the "current" turn
        let currentTurn = SessionModel.createTurn(stores, 1, null, null, null);

        let result = ContextAssembler.assemble(stores, 1, currentTurn.turnId, chStore, "C001", null);

        expect.nat(result.messages.size()).equal(0);
        expect.nat(result.stats.rawTurnsIncluded).equal(0);
      },
    );

    test(
      "records contextAssembled trace on current turn",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();
        ChannelHistoryModel.addMessage(chStore, "C001", userMsg("1000.000001", "Hello"), null);

        let currentTurn = SessionModel.createTurn(stores, 1, null, null, null);
        ignore ContextAssembler.assemble(stores, 1, currentTurn.turnId, chStore, "C001", null);

        let traces = SessionModel.getTraces(stores, currentTurn.turnId);
        switch (traces) {
          case (null) { expect.bool(false).equal(true) };
          case (?traceList) {
            var found = false;
            for (trace in List.values(traceList)) {
              switch (trace.detail) {
                case (#contextAssembled _) { found := true };
                case _ {};
              };
            };
            expect.bool(found).equal(true);
          };
        };
      },
    );
  },
);

// ── assemble – raw vs truncated field selection ───────────────────────────────

suite(
  "ContextAssembler - raw vs truncated field selection",
  func() {

    func makeTraceWithDistinctFields(stores : SessionModel.SessionStores, turnId : Text) {
      SessionModel.appendTrace(
        stores,
        turnId,
        #llmCall({
          model = "test";
          durationMs = 100;
          finishReason = "stop";
          content = ?"full raw response";
          truncatedContent = ?"truncated response";
          thinking = null;
          toolRequests = null;
          cost = {
            promptTokens = 10;
            completionTokens = 5;
            estimatedMicroUnits = 100;
          };
        }),
      );
      SessionModel.appendTrace(
        stores,
        turnId,
        #toolCall({
          name = "my_tool";
          input = "{}";
          output = "full raw output";
          truncatedOutput = ?"truncated output";
          success = true;
          durationMs = 50;
        }),
      );
    };

    test(
      "recent turn (< 1h old) uses raw content and output fields",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();

        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        makeTraceWithDistinctFields(stores, turn.turnId);
        SessionModel.completeTurn(stores, turn.turnId, #succeeded, null, null);
        // completedAtNs is Time.now() — well within 1h

        let currentTurn = SessionModel.createTurn(stores, 1, null, null, null);
        let result = ContextAssembler.assemble(stores, 1, currentTurn.turnId, chStore, "C001", null);

        expect.nat(result.stats.rawTurnsIncluded).equal(1);
        let content = result.messages[0].content;
        expect.bool(Text.contains(content, #text "full raw response")).equal(true);
        expect.bool(Text.contains(content, #text "truncated response")).equal(false);
        expect.bool(Text.contains(content, #text "full raw output")).equal(true);
        expect.bool(Text.contains(content, #text "truncated output")).equal(false);
      },
    );

    test(
      "old turn (> 1h old) uses truncatedContent and truncatedOutput fields",
      func() {
        let stores = SessionModel.emptyStores();
        let chStore = ChannelHistoryModel.empty();

        let turn = SessionModel.createTurn(stores, 1, null, null, null);
        makeTraceWithDistinctFields(stores, turn.turnId);
        SessionModel.completeTurn(stores, turn.turnId, #succeeded, null, null);

        // Backdate completedAtNs to 2 hours ago so the turn appears old
        switch (SessionModel.findTurn(stores, turn.turnId)) {
          case (null) { assert false };
          case (?t) {
            t.completedAtNs := ?(Time.now() - 2 * Constants.ONE_HOUR_NS);
          };
        };

        let currentTurn = SessionModel.createTurn(stores, 1, null, null, null);
        let result = ContextAssembler.assemble(stores, 1, currentTurn.turnId, chStore, "C001", null);

        expect.nat(result.stats.rawTurnsIncluded).equal(1);
        let content = result.messages[0].content;
        expect.bool(Text.contains(content, #text "truncated response")).equal(true);
        expect.bool(Text.contains(content, #text "full raw response")).equal(false);
        expect.bool(Text.contains(content, #text "truncated output")).equal(true);
        expect.bool(Text.contains(content, #text "full raw output")).equal(false);
      },
    );
  },
);
