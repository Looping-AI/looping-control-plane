import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import AgentRouter "../../../../src/control-plane-core/events/agent-router";
import ConversationModel "../../../../src/control-plane-core/models/conversation-model";
import SlackAuthMiddleware "../../../../src/control-plane-core/middleware/slack-auth-middleware";
import SlackUserModel "../../../../src/control-plane-core/models/slack-user-model";

// ── helpers ──────────────────────────────────────────────────────────────────

func isNoneMsg(x : ?ConversationModel.ConversationMessage) : Bool {
  switch x { case null true; case _ false };
};

func makeCtx(userId : Text, roundCount : Nat, parentRef : ?{ channelId : Text; ts : Text }) : SlackAuthMiddleware.UserAuthContext {
  {
    slackUserId = userId;
    isPrimaryOwner = false;
    isOrgAdmin = false;
    workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    roundCount;
    forceTerminated = false;
    parentRef;
  };
};

/// Build a round-0 user message.
func userMsg(ts : Text) : ConversationModel.ConversationMessage {
  {
    ts;
    userAuthContext = ?makeCtx("U_USER", 0, null);
    text = "user message";
    agentMetadata = null;
  };
};

/// Build a bot reply attributed to `agentName` (without leading "::").
func botMsg(
  ts : Text,
  agentName : Text,
  parentChannel : Text,
  parentTs : Text,
  roundCount : Nat,
  text : Text,
) : ConversationModel.ConversationMessage {
  {
    ts;
    userAuthContext = ?makeCtx("U_BOT", roundCount, ?{ channelId = parentChannel; ts = parentTs });
    text;
    agentMetadata = ?{
      parent_agent = agentName;
      parent_ts = parentTs;
      parent_channel = parentChannel;
    };
  };
};

// ═══════════════════════════════════════════════════════════════════════════════
// findPreviousSameAgentReply
//
// Walk the `parentRef` chain backwards from `startTs`, returning the first
// `ConversationMessage` whose `agentMetadata.parent_agent == agentName`.
// ═══════════════════════════════════════════════════════════════════════════════

suite(
  "AgentRouter - findPreviousSameAgentReply - message not in store",
  func() {
    test(
      "returns null when startTs is absent from an empty store",
      func() {
        let store = ConversationModel.empty();
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000001", "admin");
        expect.bool(isNoneMsg(result)).isTrue();
      },
    );
  },
);

suite(
  "AgentRouter - findPreviousSameAgentReply - chain terminates at round-0",
  func() {
    test(
      "returns null for a round-0 user message (no agentMetadata, no parentRef)",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", userMsg("1000.000001"), null);
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000001", "admin");
        expect.bool(isNoneMsg(result)).isTrue();
      },
    );

    test(
      "returns null when message has no userAuthContext (pre-auth stored message)",
      func() {
        let store = ConversationModel.empty();
        // Raw message stored before auth resolution — userAuthContext is null.
        ConversationModel.addMessage(
          store,
          "C001",
          {
            ts = "1000.000001";
            userAuthContext = null;
            text = "unauthenticated";
            agentMetadata = null;
          },
          null,
        );
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000001", "admin");
        expect.bool(isNoneMsg(result)).isTrue();
      },
    );
  },
);

suite(
  "AgentRouter - findPreviousSameAgentReply - direct match",
  func() {
    test(
      "returns the message at startTs when it is an admin reply",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", userMsg("1000.000001"), null);
        let admin1 = botMsg("1000.000002", "admin", "C001", "1000.000001", 1, "Admin reply text");
        ConversationModel.addMessage(store, "C001", admin1, null);
        // Start the walk from the admin reply itself → immediate match.
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000002", "admin");
        switch (result) {
          case (null) { expect.bool(false).isTrue() }; // should not be null
          case (?msg) { expect.text(msg.ts).equal("1000.000002") };
        };
      },
    );
  },
);

suite(
  "AgentRouter - findPreviousSameAgentReply - cross-agent chain returns null",
  func() {
    test(
      "returns null when chain only contains replies from a different agent",
      func() {
        let store = ConversationModel.empty();
        ConversationModel.addMessage(store, "C001", userMsg("1000.000001"), null);
        let researchReply = botMsg("1000.000002", "research", "C001", "1000.000001", 1, "Research reply");
        ConversationModel.addMessage(store, "C001", researchReply, null);
        // Walk looking for "admin" — the chain only has "research" then terminates.
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000002", "admin");
        expect.bool(isNoneMsg(result)).isTrue();
      },
    );
  },
);

suite(
  "AgentRouter - findPreviousSameAgentReply - three-message chain walk",
  func() {
    test(
      "skips ::research reply and finds earlier ::admin reply (three-node chain)",
      func() {
        let store = ConversationModel.empty();
        // 1. User message (round 0)
        ConversationModel.addMessage(store, "C001", userMsg("1000.000001"), null);
        // 2. ::admin reply (round 1) — c001:1000.000001 → reply at c001:1000.000002
        let adminReply = botMsg("1000.000002", "admin", "C001", "1000.000001", 1, "Admin reply text");
        ConversationModel.addMessage(store, "C001", adminReply, null);
        // 3. ::research reply (round 2) — parentRef points to admin reply
        let researchReply = botMsg("1000.000003", "research", "C001", "1000.000002", 2, "Research reply text");
        ConversationModel.addMessage(store, "C001", researchReply, null);
        // A round-3 ::admin message would have parent_ts = "1000.000003" (the research reply).
        // Walk: 1000.000003 (research) → not admin → follow parentRef → 1000.000002 (admin) → match.
        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1000.000003", "admin");
        switch (result) {
          case (null) { expect.bool(false).isTrue() }; // should have found the admin reply
          case (?msg) {
            expect.text(msg.ts).equal("1000.000002");
            expect.text(msg.text).equal("Admin reply text");
          };
        };
      },
    );

    test(
      "skips multiple intervening agents and finds the matching one",
      func() {
        let store = ConversationModel.empty();
        // Chain: user → admin (r1) → research (r2) → communication (r3)
        // Walk from r3 looking for "admin" → should skip r3 and r2, find r1.
        ConversationModel.addMessage(store, "C001", userMsg("1001.000001"), null);
        let r1 = botMsg("1001.000002", "admin", "C001", "1001.000001", 1, "Admin reply");
        ConversationModel.addMessage(store, "C001", r1, null);
        let r2 = botMsg("1001.000003", "research", "C001", "1001.000002", 2, "Research reply");
        ConversationModel.addMessage(store, "C001", r2, null);
        let r3 = botMsg("1001.000004", "communication", "C001", "1001.000003", 3, "Communication reply");
        ConversationModel.addMessage(store, "C001", r3, null);

        let result = AgentRouter.findPreviousSameAgentReply(store, "C001", "1001.000004", "admin");
        switch (result) {
          case (null) { expect.bool(false).isTrue() };
          case (?msg) { expect.text(msg.ts).equal("1001.000002") };
        };
      },
    );
  },
);

suite(
  "AgentRouter - findPreviousSameAgentReply - cross-channel parentRef",
  func() {
    test(
      "follows parentRef across channels and returns the match",
      func() {
        let store = ConversationModel.empty();
        // User message in C001
        ConversationModel.addMessage(store, "C001", userMsg("2000.000001"), null);
        // Admin reply in C002 (cross-channel reply), parentRef points back to C001
        let adminInC2 = botMsg("2000.000002", "admin", "C001", "2000.000001", 1, "Cross-channel admin reply");
        ConversationModel.addMessage(store, "C002", adminInC2, null);
        // Research in C002, parentRef points to admin reply in C002
        let researchInC2 = botMsg("2000.000003", "research", "C002", "2000.000002", 2, "Cross-channel research reply");
        ConversationModel.addMessage(store, "C002", researchInC2, null);

        // Walk from C002:"2000.000003" looking for "admin":
        //   → 2000.000003 (research in C002) — no match → follow parentRef to C002:2000.000002
        //   → 2000.000002 (admin in C002) — MATCH
        let result = AgentRouter.findPreviousSameAgentReply(store, "C002", "2000.000003", "admin");
        switch (result) {
          case (null) { expect.bool(false).isTrue() };
          case (?msg) { expect.text(msg.ts).equal("2000.000002") };
        };
      },
    );
  },
);
