import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";

import HttpWrapper "../../../src/open-org-backend/wrappers/http-wrapper";
import GroqWrapper "../../../src/open-org-backend/wrappers/groq-wrapper";
import SlackWrapper "../../../src/open-org-backend/wrappers/slack-wrapper";
import HttpCertification "../../../src/open-org-backend/utilities/http-certification";
import MessageHandler "../../../src/open-org-backend/events/handlers/message-handler";
import MessageDeletedHandler "../../../src/open-org-backend/events/handlers/message-deleted-handler";
import MessageEditedHandler "../../../src/open-org-backend/events/handlers/message-edited-handler";
import AssistantThreadHandler "../../../src/open-org-backend/events/handlers/assistant-thread-handler";
import TeamJoinHandler "../../../src/open-org-backend/events/handlers/team-join-handler";
import MemberJoinedChannelHandler "../../../src/open-org-backend/events/handlers/member-joined-channel-handler";
import MemberLeftChannelHandler "../../../src/open-org-backend/events/handlers/member-left-channel-handler";
import NormalizedEventTypes "../../../src/open-org-backend/events/types/normalized-event-types";
import SlackAdapter "../../../src/open-org-backend/events/slack-adapter";
import EventProcessingContextTypes "../../../src/open-org-backend/events/types/event-processing-context";
import McpToolRegistry "../../../src/open-org-backend/tools/mcp-tool-registry";
import AgentModel "../../../src/open-org-backend/models/agent-model";
import WeeklyReconciliationService "../../../src/open-org-backend/services/weekly-reconciliation-service";
import ValueStreamModel "../../../src/open-org-backend/models/value-stream-model";
import ObjectiveModel "../../../src/open-org-backend/models/objective-model";
import MetricModel "../../../src/open-org-backend/models/metric-model";
import ConversationModel "../../../src/open-org-backend/models/conversation-model";
import SecretModel "../../../src/open-org-backend/models/secret-model";
import SlackUserModel "../../../src/open-org-backend/models/slack-user-model";
import SlackAuthMiddleware "../../../src/open-org-backend/middleware/slack-auth-middleware";
import WorkspaceModel "../../../src/open-org-backend/models/workspace-model";
import KeyDerivationService "../../../src/open-org-backend/services/key-derivation-service";
import Types "../../../src/open-org-backend/types";

// ============================================
// Test Canister
// ============================================

// IMPORTANT:
// Never add this canister to dfx or deploy it

shared ({ caller = parent }) persistent actor class TestCanister() {
  // Store for HTTP certification testing
  var certStore = HttpCertification.initStore();

  // Persistent Slack user state for tests (cache + access change log).
  // This allows us to verify state changes and audit log entries across handler calls.
  var slackUsers = SlackUserModel.emptyState();

  // Persistent key cache for testing key derivation mechanics.
  // Starts empty; tests seed it via testSeedKeyForWorkspace or test methods.
  var testKeyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache();

  // Pre-seeded workspace state with channel anchors for handler tests.
  //   Workspace 0: Default (no channel anchors) — from emptyState()
  //   Workspace 1: adminChannelId = C_ADMIN_CHANNEL, memberChannelId = C_MEMBER_CHANNEL
  //   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN, memberChannelId = C_ROUND_TRIP_MEMBER
  let testWorkspacesState : WorkspaceModel.WorkspacesState = do {
    let s = WorkspaceModel.emptyState();
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 1"); // id = 1
    ignore WorkspaceModel.setAdminChannel(s, 1, "C_ADMIN_CHANNEL");
    ignore WorkspaceModel.setMemberChannel(s, 1, "C_MEMBER_CHANNEL");
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 2"); // id = 2
    ignore WorkspaceModel.setAdminChannel(s, 2, "C_ROUND_TRIP_ADMIN");
    ignore WorkspaceModel.setMemberChannel(s, 2, "C_ROUND_TRIP_MEMBER");
    s;
  };

  // ============================================
  // Test Helpers
  // ============================================

  /// The deterministic 32-byte all-zeros key used for every workspace in unit tests.
  /// Seeding keyCache with this key avoids live Schnorr threshold-key calls.
  private let testDummyKey : [Nat8] = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];

  /// Creates an empty EventProcessingContext suitable for unit tests.
  /// Secrets are not populated so handlers that require them will return graceful
  /// error steps rather than crashing.
  /// Uses the persistent slackUserCache so state changes persist across handler calls.
  private func emptyCtx() : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    {
      secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
      keyCache;
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = AgentModel.emptyState();
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces = testWorkspacesState;
    };
  };

  /// Creates an EventProcessingContext pre-seeded with a Slack bot token and a Groq
  /// API key, both encrypted with the deterministic dummy key used across unit tests.
  /// This lets message-handler tests reach the Slack-posting code path without live
  /// Schnorr key derivation or a real secret-store call.
  ///
  /// Secrets are stored for workspace IDs 0, 1, and 42.
  /// Uses the persistent slackUserCache so state changes persist across handler calls.
  private func ctxWithSecrets(botToken : Text, groqApiKey : Text) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
    for (wsId in [0, 1, 42].vals()) {
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #slackBotToken, botToken);
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #groqApiKey, groqApiKey);
    };
    // Register an admin agent permitted to access groqApiKey for workspaces 0, 1, and 42
    let registry = AgentModel.emptyState();
    ignore AgentModel.register(
      "unit-test-admin",
      #admin,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    {
      secrets;
      keyCache;
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = registry;
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces = testWorkspacesState;
    };
  };

  /// Like `ctxWithSecrets`, but stores the Groq API key ONLY — no Slack bot token.
  ///
  /// Use this for guard tests (e.g. MAX_AGENT_ROUNDS, force-termination guards) that
  /// run on a non-deferred actor without cassette support.  When there is no
  /// `#slackBotToken` secret for the workspace, `resolveWorkspaceBotToken` returns
  /// null so `postTerminationIfTokenAvailable` is a no-op and no outgoing HTTPS call
  /// is attempted.  This avoids the pending-outcall problem in non-cassette tests.
  private func ctxWithGroqOnlySecrets(groqApiKey : Text) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
    for (wsId in [0, 1, 42].vals()) {
      // NOTE: #slackBotToken intentionally absent — keeps postTerminationPrompt a no-op.
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #groqApiKey, groqApiKey);
    };
    let registry = AgentModel.emptyState();
    ignore AgentModel.register(
      "unit-test-admin",
      #admin,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    {
      secrets;
      keyCache;
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = registry;
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces = testWorkspacesState;
    };
  };

  /// Like `ctxWithSecrets`, but also registers a `unit-test-research` agent with
  /// `#research` category alongside the existing `unit-test-admin`.
  ///
  /// Use this context when a test needs to exercise primary agent resolution via
  /// an explicit `::unit-test-research` reference.
  private func ctxWithSecretsAndResearch(botToken : Text, groqApiKey : Text) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
    for (wsId in [0, 1, 42].vals()) {
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #slackBotToken, botToken);
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #groqApiKey, groqApiKey);
    };
    let registry = AgentModel.emptyState();
    // Admin agent (same as ctxWithSecrets)
    ignore AgentModel.register(
      "unit-test-admin",
      #admin,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    // Research agent — no real secret needed; route(#research) returns a stub error
    // without making any HTTP calls, so a dummy secret entry is sufficient.
    ignore AgentModel.register(
      "unit-test-research",
      #research,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    {
      secrets;
      keyCache;
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = registry;
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces = testWorkspacesState;
    };
  };

  // ============================================
  // Slack Wrapper Test Methods
  // ============================================

  public shared ({ caller }) func slackGetOrganizationMembers(token : Text) : async {
    #ok : [SlackWrapper.SlackUser];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getOrganizationMembers(token);
  };

  public shared ({ caller }) func slackListChannels(token : Text, types : ?Text) : async {
    #ok : [SlackWrapper.SlackChannel];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.listChannels(token, types);
  };

  public shared ({ caller }) func slackGetChannelMembers(token : Text, channel : Text) : async {
    #ok : [Text];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getChannelMembers(token, channel);
  };

  // ============================================
  // HTTP Wrapper Test Methods
  // ============================================

  public shared ({ caller }) func httpGet(url : Text, headers : [HttpWrapper.HttpHeader]) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.get(url, headers);
  };

  public shared ({ caller }) func httpPost(url : Text, headers : [HttpWrapper.HttpHeader], body : Text) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.post(url, headers, body);
  };

  public shared ({ caller }) func groqChat(apiKey : Text, userMessage : Text, model : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.chat(apiKey, userMessage, model);
  };

  public shared ({ caller }) func groqReason(
    apiKey : Text,
    input : [GroqWrapper.ResponseInputMessage],
    model : Text,
    trackId : GroqWrapper.TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[GroqWrapper.Tool],
  ) : async GroqWrapper.ReasonWithToolsResult {
    assert caller == parent;
    await GroqWrapper.reason(apiKey, input, model, trackId, instructions, temperature, tools);
  };

  public shared ({ caller }) func groqUseBuiltInTool(
    apiKey : Text,
    userMessage : Text,
    tool : GroqWrapper.BuiltInTool,
  ) : async {
    #ok : GroqWrapper.CompoundChatCompletionResponse;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.useBuiltInTool(apiKey, userMessage, tool);
  };

  // ============================================
  // HTTP Certification Methods
  // ============================================

  public shared ({ caller }) func httpCertInit() : async () {
    assert caller == parent;
    certStore := HttpCertification.initStore();
  };

  public shared ({ caller }) func httpCertCertifyPath(url : Text) : async () {
    assert caller == parent;
    HttpCertification.certifySkipFallbackPath(certStore, url);
  };

  public query func httpCertGetHeaders(url : Text) : async {
    #ok : [(Text, Text)];
    #err : Text;
  } {
    try {
      let headers = HttpCertification.getSkipCertificationHeaders(certStore, url);
      #ok(headers);
    } catch (_) {
      #err("Failed to get headers");
    };
  };

  /// Check if a path exists in the MerkleTree and return its details
  public query func httpCertCheckPath(url : Text) : async {
    #ok : {
      exists : Bool;
      path : [Text];
      treeHash : Blob;
    };
    #err : Text;
  } {
    try {
      let result = HttpCertification.checkPath(certStore, url);
      #ok(result);
    } catch (e) {
      #err("Failed to check path: " # Error.message(e));
    };
  };

  // ============================================
  // Handler Test Methods
  // ============================================

  public shared ({ caller }) func testMessageHandler(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(msg, emptyCtx());
  };

  /// Like testMessageHandler, but pre-seeds the context with a real Slack bot token
  /// and Groq API key so the full happy-path (LLM call → Slack post) can be exercised
  /// and captured with the cassette recording system.
  public shared ({ caller }) func testMessageHandlerWithSecrets(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    groqApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(msg, ctxWithSecrets(botToken, groqApiKey));
  };

  /// Like testMessageHandlerWithSecrets, but also pre-seeds the conversation store
  /// with a parent message that carries a UserAuthContext at a specified roundCount.
  /// This allows bot-message (isBotMessage: true) tests to exercise session
  /// inheritance and MAX_AGENT_ROUNDS termination logic without live HTTP calls
  /// or requiring external cassettes.
  ///
  /// parentChannel        — channel where the parent message lives.
  /// parentTs             — ts of the parent message (also used as rootTs for a top-level post).
  /// parentRoundCount     — roundCount stamped on the parent's userAuthContext.
  /// parentForceTerminated — forceTerminated flag on the parent's userAuthContext.
  public shared ({ caller }) func testMessageHandlerBotBranch(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    groqApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    parentRoundCount : Nat,
    parentForceTerminated : Bool,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    let ctx = ctxWithSecrets(botToken, groqApiKey);
    // Seed the parent message with a UserAuthContext at the requested roundCount.
    // workspaceScopes is empty — the bot-path guard only checks roundCount / forceTerminated.
    //
    // Respect the invariant: parentRef == null ↔ roundCount == 0.
    // When parentRoundCount > 0 a real context would carry the channelId+ts of the
    // message that triggered it, so we populate parentRef accordingly.
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
      roundCount = parentRoundCount;
      forceTerminated = parentForceTerminated;
      parentRef = if (parentRoundCount == 0) null else ?{
        channelId = parentChannel;
        ts = parentTs;
      };
    };
    ConversationModel.addMessage(
      ctx.conversationStore,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ConversationModel.updateMessageContext(
      ctx.conversationStore,
      parentChannel,
      parentTs, // rootTs — this is a top-level post so rootTs == ts
      parentTs, // msgTs
      ?parentAuthCtx,
    );
    await MessageHandler.handle(msg, ctx);
  };

  /// Like `testMessageHandlerBotBranch`, but uses `ctxWithGroqOnlySecrets` (no Slack
  /// bot token) so the `postTerminationIfTokenAvailable` call is a no-op.
  ///
  /// Use this for non-deferred guard tests that verify termination logic (e.g.
  /// MAX_AGENT_ROUNDS, forceTerminated) without needing a cassette to handle the
  /// outgoing Slack HTTPS chat.postMessage call.
  public shared ({ caller }) func testMessageHandlerBotBranchNoSlackToken(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    groqApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    parentRoundCount : Nat,
    parentForceTerminated : Bool,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    let ctx = ctxWithGroqOnlySecrets(groqApiKey);
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
      roundCount = parentRoundCount;
      forceTerminated = parentForceTerminated;
      parentRef = if (parentRoundCount == 0) null else ?{
        channelId = parentChannel;
        ts = parentTs;
      };
    };
    ConversationModel.addMessage(
      ctx.conversationStore,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ConversationModel.updateMessageContext(
      ctx.conversationStore,
      parentChannel,
      parentTs,
      parentTs,
      ?parentAuthCtx,
    );
    await MessageHandler.handle(msg, ctx);
  };

  /// Like `testMessageHandlerWithSecrets`, but pre-seeds the context with BOTH a
  /// `unit-test-admin` (#admin) and a `unit-test-research` (#research) agent.
  ///
  /// Use this variant for primary-agent resolution tests that reference `::unit-test-research`
  /// explicitly.  Because `route(#research, …)` returns a stub error without making any HTTP
  /// calls, these tests complete quickly with no cassette required.
  public shared ({ caller }) func testMessageHandlerWithResearchAgent(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
    groqApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(msg, ctxWithSecretsAndResearch(botToken, groqApiKey));
  };

  /// Like `ctxWithSecretsAndResearch`, but does NOT seed a Groq API key secret.
  /// When the admin route tries to decrypt the groqApiKey it finds null and returns
  /// #err immediately, without issuing any HTTPS outcall.
  ///
  /// Use for non-deferred primary-agent resolution tests that need to verify the
  /// fallback-to-admin path without triggering a live (or cassette-dependent) LLM call.
  private func ctxWithSecretsAndResearchNoGroq(botToken : Text) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
    for (wsId in [0, 1, 42].vals()) {
      // NOTE: #groqApiKey intentionally absent — keeps admin route a sync no-op.
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #slackBotToken, botToken);
    };
    let registry = AgentModel.emptyState();
    ignore AgentModel.register(
      "unit-test-admin",
      #admin,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    ignore AgentModel.register(
      "unit-test-research",
      #research,
      #groq(#gpt_oss_120b),
      [(0, #groqApiKey), (1, #groqApiKey), (42, #groqApiKey)],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    {
      secrets;
      keyCache;
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = registry;
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces = testWorkspacesState;
    };
  };

  /// Like `testMessageHandlerWithResearchAgent`, but uses `ctxWithSecretsAndResearchNoGroq`
  /// so the admin route short-circuits at key resolution (#err) without any HTTP outcall.
  ///
  /// Use for primary-agent fallback tests on a non-deferred actor where you only need
  /// to assert that the agent WAS resolved (i.e. primary_agent_skip is NOT emitted).
  public shared ({ caller }) func testMessageHandlerWithResearchAgentNoGroq(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    botToken : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(msg, ctxWithSecretsAndResearchNoGroq(botToken));
  };

  public shared ({ caller }) func testMessageDeletedHandler(
    deleted : {
      channel : Text;
      deletedTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageDeletedHandler.handle(deleted, emptyCtx());
  };

  public shared ({ caller }) func testMessageEditedHandler(
    edited : {
      channel : Text;
      messageTs : Text;
      threadTs : ?Text;
      newText : Text;
      editedBy : ?Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageEditedHandler.handle(edited, emptyCtx());
  };

  public shared ({ caller }) func testAssistantThreadEventHandler(
    thread : {
      eventType : { #threadStarted; #threadContextChanged };
      userId : Text;
      channelId : Text;
      threadTs : Text;
      eventTs : Text;
      context : NormalizedEventTypes.AssistantThreadContext;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await AssistantThreadHandler.handle(thread, emptyCtx());
  };

  public shared ({ caller }) func testTeamJoinHandler(
    event : {
      userId : Text;
      displayName : Text;
      realName : ?Text;
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await TeamJoinHandler.handle(event, emptyCtx());
  };

  public shared ({ caller }) func testMemberJoinedChannelHandler(
    event : {
      userId : Text;
      channelId : Text;
      channelType : Text;
      teamId : Text;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MemberJoinedChannelHandler.handle(event, emptyCtx());
  };

  public shared ({ caller }) func testMemberLeftChannelHandler(
    event : {
      userId : Text;
      channelId : Text;
      channelType : Text;
      teamId : Text;
      eventTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MemberLeftChannelHandler.handle(event, emptyCtx());
  };

  // ============================================
  // Slack User Cache Query Methods
  // ============================================

  /// Serializable version of SlackUserEntry for Candid response
  public type SlackUserInfo = {
    slackUserId : Text;
    displayName : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    isBot : Bool;
    workspaceMemberships : [(Nat, { #admin; #member })];
  };

  /// Serializable version of AccessChangeEntry for Candid response.
  /// `source` is encoded as a plain string: "reconciliation", "manual", or "slackEvent:<eventId>".
  /// `changeType` is encoded as the variant name (e.g. "orgAdminGranted").
  /// `workspaceId` is populated only for workspace-scoped change types.
  public type ChangeLogEntryInfo = {
    slackUserId : Text;
    changeType : Text;
    source : Text;
    workspaceId : ?Nat;
  };

  /// Reset the Slack user state (cache + change log) for test isolation.
  public func resetSlackUserCache() : async () {
    slackUsers := SlackUserModel.emptyState();
  };

  /// Get all Slack users currently in the cache
  public query func getSlackUsers() : async [SlackUserInfo] {
    let entries = SlackUserModel.listUsers(slackUsers.cache);
    Array.map<SlackUserModel.SlackUserEntry, SlackUserInfo>(
      entries,
      func(entry : SlackUserModel.SlackUserEntry) : SlackUserInfo {
        let memberships = SlackUserModel.getWorkspaceMemberships(entry);
        {
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          workspaceMemberships = memberships;
        };
      },
    );
  };

  /// Look up a specific Slack user by ID
  public query func getSlackUser(slackUserId : Text) : async ?SlackUserInfo {
    switch (SlackUserModel.lookupUser(slackUsers.cache, slackUserId)) {
      case (null) { null };
      case (?entry) {
        let memberships = SlackUserModel.getWorkspaceMemberships(entry);
        ?({
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          workspaceMemberships = memberships;
        });
      };
    };
  };

  /// Return all access change log entries recorded in the current state.
  /// Entries are in chronological order (oldest first).
  public query func getChangeLog() : async [ChangeLogEntryInfo] {
    let entries = SlackUserModel.getLogsSince(slackUsers, 0);
    Array.map<SlackUserModel.AccessChangeEntry, ChangeLogEntryInfo>(
      entries,
      func(e : SlackUserModel.AccessChangeEntry) : ChangeLogEntryInfo {
        let changeTypeText = switch (e.changeType) {
          case (#userAdded) { "userAdded" };
          case (#userRemoved) { "userRemoved" };
          case (#orgAdminGranted) { "orgAdminGranted" };
          case (#orgAdminRevoked) { "orgAdminRevoked" };
          case (#primaryOwnerGranted) { "primaryOwnerGranted" };
          case (#primaryOwnerRevoked) { "primaryOwnerRevoked" };
          case (#workspaceAdminGranted(_)) { "workspaceAdminGranted" };
          case (#workspaceAdminRevoked(_)) { "workspaceAdminRevoked" };
          case (#workspaceMemberGranted(_)) { "workspaceMemberGranted" };
          case (#workspaceMemberRevoked(_)) { "workspaceMemberRevoked" };
        };
        let wsIdOpt : ?Nat = switch (e.changeType) {
          case (#workspaceAdminGranted(wsId)) { ?wsId };
          case (#workspaceAdminRevoked(wsId)) { ?wsId };
          case (#workspaceMemberGranted(wsId)) { ?wsId };
          case (#workspaceMemberRevoked(wsId)) { ?wsId };
          case (_) { null };
        };
        let sourceText = switch (e.source) {
          case (#reconciliation) { "reconciliation" };
          case (#slackEvent(eventId)) { "slackEvent:" # eventId };
          case (#manual) { "manual" };
        };
        {
          slackUserId = e.slackUserId;
          changeType = changeTypeText;
          source = sourceText;
          workspaceId = wsIdOpt;
        };
      },
    );
  };

  // ============================================
  // Weekly Reconciliation Service Test Methods
  // ============================================

  /// Seed a single Slack user into the persistent state for reconciliation tests.
  public shared ({ caller }) func seedSlackUser(
    slackUserId : Text,
    displayName : Text,
    isPrimaryOwner : Bool,
    isOrgAdmin : Bool,
    isBot : Bool,
  ) : async () {
    assert caller == parent;
    SlackUserModel.upsertUser(
      slackUsers,
      {
        slackUserId;
        displayName;
        isPrimaryOwner;
        isOrgAdmin;
        isBot;
        workspaceMemberships = Map.empty<Nat, SlackUserModel.WorkspaceChannelFlags>();
      },
      #manual,
    );
  };

  /// Seed a workspace channel membership for a user in the persistent state.
  /// The user must already exist in the cache (seed via seedSlackUser first).
  public shared ({ caller }) func seedWorkspaceMembership(
    slackUserId : Text,
    workspaceId : Nat,
    slot : { #admin; #member },
  ) : async () {
    assert caller == parent;
    switch (slot) {
      case (#admin) {
        ignore SlackUserModel.joinAdminChannel(slackUsers, slackUserId, workspaceId, #manual);
      };
      case (#member) {
        ignore SlackUserModel.joinMemberChannel(slackUsers, slackUserId, workspaceId, #manual);
      };
    };
  };

  /// Run the weekly reconciliation service against the shared test cache and
  /// the pre-seeded test workspace state.
  ///
  /// @param token               Decrypted Slack bot token (or mock value)
  /// @param orgAdminChannelId   Optional org-admin channel ID
  /// @param orgAdminChannelName Optional org-admin channel display name (required when ID is provided)
  public shared ({ caller }) func testWeeklyReconciliation(
    token : Text,
    orgAdminChannelId : ?Text,
    orgAdminChannelName : ?Text,
  ) : async WeeklyReconciliationService.ReconciliationSummary {
    assert caller == parent;
    let orgAdminChannel : ?WorkspaceModel.OrgAdminChannelAnchor = switch (
      orgAdminChannelId,
      orgAdminChannelName,
    ) {
      case (?id, ?name) { ?{ channelId = id; channelName = name } };
      case _ { null };
    };
    await WeeklyReconciliationService.run(
      token,
      slackUsers,
      testWorkspacesState,
      orgAdminChannel,
    );
  };

  // ============================================
  // Slack Adapter Test Methods
  // ============================================

  public query func testSlackSignatureVerification(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : async Bool {
    SlackAdapter.verifySignature(signingSecret, signature, timestamp, body);
  };

  public query func testSlackTimestampVerification(timestamp : Text) : async Bool {
    SlackAdapter.verifyTimestamp(timestamp);
  };

  // ============================================
  // Key Derivation Service Test Methods
  // ============================================

  /// Returns the current number of entries in the persistent test key cache.
  public query func testGetKeyCacheSize() : async Nat {
    KeyDerivationService.getCacheSize(testKeyCache);
  };

  /// Clears the persistent test key cache, simulating the periodic cache-clearing timer.
  public shared ({ caller }) func testClearKeyCache() : async () {
    assert caller == parent;
    testKeyCache := KeyDerivationService.clearCache();
  };

  /// Derives and caches the encryption key for a workspace via a live sign_with_schnorr call.
  /// Requires the canister to be deployed on a subnet with fiduciary (threshold Schnorr) support.
  public shared ({ caller }) func testSeedKeyForWorkspace(workspaceId : Nat) : async () {
    assert caller == parent;
    let key = await KeyDerivationService.deriveKeyFromSchnorr(workspaceId);
    Map.add(testKeyCache, Nat.compare, workspaceId, key);
  };

  /// Returns the byte-length of the cached key for the given workspace, or null if not cached.
  /// Use this to confirm the dummy key has been stored (expected length = 32).
  public query func testGetCachedKeyLength(workspaceId : Nat) : async ?Nat {
    switch (Map.get(testKeyCache, Nat.compare, workspaceId)) {
      case (?key) { ?key.size() };
      case (null) { null };
    };
  };
};
