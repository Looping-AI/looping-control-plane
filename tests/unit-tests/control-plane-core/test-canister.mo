import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Set "mo:core/Set";
import Text "mo:core/Text";

import HttpWrapper "../../../src/control-plane-core/wrappers/http-wrapper";
import OpenRouterWrapper "../../../src/control-plane-core/wrappers/openrouter-wrapper";
import SlackWrapper "../../../src/control-plane-core/wrappers/slack-wrapper";
import HttpCertification "../../../src/control-plane-core/utilities/http-certification";
import MessageHandler "../../../src/control-plane-core/events/handlers/message-handler";
import MessageDeletedHandler "../../../src/control-plane-core/events/handlers/message-deleted-handler";
import MessageEditedHandler "../../../src/control-plane-core/events/handlers/message-edited-handler";
import AssistantThreadHandler "../../../src/control-plane-core/events/handlers/assistant-thread-handler";
import TeamJoinHandler "../../../src/control-plane-core/events/handlers/team-join-handler";
import MemberJoinedChannelHandler "../../../src/control-plane-core/events/handlers/member-joined-channel-handler";
import MemberLeftChannelHandler "../../../src/control-plane-core/events/handlers/member-left-channel-handler";
import NormalizedEventTypes "../../../src/control-plane-core/events/types/normalized-event-types";
import SlackAdapter "../../../src/control-plane-core/events/slack-adapter";
import SetWorkspaceAdminChannelHandler "../../../src/control-plane-core/tools/handlers/workspaces/set-workspace-admin-channel-handler";

import CreateWorkspaceHandler "../../../src/control-plane-core/tools/handlers/workspaces/create-workspace-handler";
import DeleteWorkspaceHandler "../../../src/control-plane-core/tools/handlers/workspaces/delete-workspace-handler";
import ListWorkspacesHandler "../../../src/control-plane-core/tools/handlers/workspaces/list-workspaces-handler";
import RegisterAgentHandler "../../../src/control-plane-core/tools/handlers/agents/register-agent-handler";
import ListAgentsHandler "../../../src/control-plane-core/tools/handlers/agents/list-agents-handler";
import GetAgentHandler "../../../src/control-plane-core/tools/handlers/agents/get-agent-handler";
import UpdateAgentHandler "../../../src/control-plane-core/tools/handlers/agents/update-agent-handler";
import UnregisterAgentHandler "../../../src/control-plane-core/tools/handlers/agents/unregister-agent-handler";
import RegisterMcpToolHandler "../../../src/control-plane-core/tools/handlers/mcp/register-mcp-tool-handler";
import UnregisterMcpToolHandler "../../../src/control-plane-core/tools/handlers/mcp/unregister-mcp-tool-handler";
import ListMcpToolsHandler "../../../src/control-plane-core/tools/handlers/mcp/list-mcp-tools-handler";
import StoreSecretHandler "../../../src/control-plane-core/tools/handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "../../../src/control-plane-core/tools/handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "../../../src/control-plane-core/tools/handlers/secrets/delete-secret-handler";
import GetEventStoreStatsHandler "../../../src/control-plane-core/tools/handlers/events/get-event-store-stats-handler";
import GetFailedEventsHandler "../../../src/control-plane-core/tools/handlers/events/get-failed-events-handler";
import DeleteFailedEventsHandler "../../../src/control-plane-core/tools/handlers/events/delete-failed-events-handler";
import WeeklyReconciliationRunner "../../../src/control-plane-core/timers/weekly-reconciliation-runner";
import ClearKeyCacheRunner "../../../src/control-plane-core/timers/clear-key-cache-runner";
import ProcessedEventsCleanupRunner "../../../src/control-plane-core/timers/processed-events-cleanup-runner";
import ChannelHistoryPruneRunner "../../../src/control-plane-core/timers/channel-history-prune-runner";
import SlackEventIntakeService "../../../src/control-plane-core/services/slack-event-intake-service";
import ChannelHistoryModel "../../../src/control-plane-core/models/channel-history-model";
import SlackUserModel "../../../src/control-plane-core/models/slack-user-model";
import SlackAuthMiddleware "../../../src/control-plane-core/middleware/slack-auth-middleware";
import WorkspaceModel "../../../src/control-plane-core/models/workspace-model";
import AgentModel "../../../src/control-plane-core/models/agent-model";
import McpToolRegistry "../../../src/control-plane-core/tools/mcp-tool-registry";
import KeyDerivationService "../../../src/control-plane-core/services/key-derivation-service";
import SecretModel "../../../src/control-plane-core/models/secret-model";
import EventStoreModel "../../../src/control-plane-core/models/event-store-model";
import SessionModel "../../../src/control-plane-core/models/session-model";
import Types "../../../src/control-plane-core/types";
import TestHelpers "./test-helpers";

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
  //   Workspace 1: adminChannelId = C_ADMIN_CHANNEL
  //   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN
  let testWorkspacesState : WorkspaceModel.WorkspacesState = do {
    let s = WorkspaceModel.emptyState();
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 1"); // id = 1
    ignore WorkspaceModel.setAdminChannel(s, 1, "C_ADMIN_CHANNEL");
    ignore WorkspaceModel.createWorkspace(s, "Test Workspace 2"); // id = 2
    ignore WorkspaceModel.setAdminChannel(s, 2, "C_ROUND_TRIP_ADMIN");
    s;
  };

  // Agent registry state for agent handler tests. Starts empty; tests
  // register agents through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  let testAgentRegistry = AgentModel.emptyState();

  // MCP tool registry state for MCP handler tests. Starts empty; tests
  // register tools through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  let testMcpToolRegistry = McpToolRegistry.empty();

  // Secrets map and key cache for secrets handler tests. Starts empty; tests
  // store/delete secrets through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  // The key cache is pre-seeded with the all-zeros dummy key for workspaces 0, 1, 2
  // to avoid live Schnorr calls during unit tests.
  let testSecretsMap = SecretModel.initState();
  let testSecretsKeyCache : KeyDerivationService.KeyCache = Map.fromArray<Nat, [Nat8]>(
    [(0, TestHelpers.dummyKey), (1, TestHelpers.dummyKey), (2, TestHelpers.dummyKey)],
    Nat.compare,
  );

  // Event store state for event handler tests. Starts empty; tests seed events
  // through the testSeedFailedEvent helper and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  let testEventStore = EventStoreModel.empty();

  // Channel history store for channel-history-prune runner tests.
  let testChannelHistoryStore = ChannelHistoryModel.empty();

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

  public shared ({ caller }) func openRouterChat(apiKey : Text, userMessage : Text, model : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    assert caller == parent;
    await OpenRouterWrapper.chat(apiKey, userMessage, model);
  };

  public shared ({ caller }) func openRouterReason(
    apiKey : Text,
    input : [OpenRouterWrapper.ResponseInputMessage],
    model : Text,
    trackId : OpenRouterWrapper.TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[OpenRouterWrapper.Tool],
  ) : async OpenRouterWrapper.ReasonWithToolsResult {
    assert caller == parent;
    await OpenRouterWrapper.reason(apiKey, input, model, trackId, instructions, temperature, tools);
  };

  public shared ({ caller }) func openRouterUseBuiltInTool(
    apiKey : Text,
    userMessage : Text,
    tool : OpenRouterWrapper.BuiltInTool,
  ) : async {
    #ok : OpenRouterWrapper.CompoundChatCompletionResponse;
    #err : Text;
  } {
    assert caller == parent;
    await OpenRouterWrapper.useBuiltInTool(apiKey, userMessage, tool);
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
  // Events Handler Test Methods
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
    await MessageHandler.handle(msg, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
  };

  /// Like testMessageHandler, but pre-seeds the context with a real Slack bot token
  /// and OpenRouter API key so the full happy-path (LLM call → Slack post) can be exercised
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
    openRouterApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    // Anchor workspace 0's admin channel to the incoming channel so the admin routing
    // guard passes. The setAdminChannel call is silently ignored if the channel is
    // already anchored to another workspace (e.g. C_ADMIN_CHANNEL → workspace 1 in
    // testWorkspacesState), which is fine for tests that fire before the routing guard.
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  /// Like testMessageHandlerWithSecrets, but also pre-seeds the conversation store
  /// with a parent message that carries a UserAuthContext and optionally seeds
  /// a delegation-depth chain in the session stores.
  /// This allows bot-message (isBotMessage: true) tests to exercise delegation
  /// depth checks and MAX_AGENT_ROUNDS termination logic.
  ///
  /// parentChannel     — channel where the parent message lives.
  /// parentTs          — ts of the parent message (also used as rootTs for a top-level post).
  /// delegationDepth   — number of turns to chain in sessionStores (0 = no prior delegation).
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
    openRouterApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    delegationDepth : Nat,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    let ctx = TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]);
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      ctx.channelHistory,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ChannelHistoryModel.updateMessageContext(
      ctx.channelHistory,
      parentChannel,
      parentTs,
      parentTs,
      ?parentAuthCtx,
    );
    // Seed a delegation chain in the session stores
    var prevTurnId : ?Text = null;
    var i = 0;
    while (i < delegationDepth) {
      let turn = SessionModel.createTurn(ctx.sessionStores, 0, null, prevTurnId, ?parentAuthCtx);
      SessionModel.completeTurn(ctx.sessionStores, turn.turnId, #succeeded, null, null);
      prevTurnId := ?turn.turnId;
      i += 1;
    };
    // Override turn_id only when turns were seeded; otherwise pass msg through unchanged.
    let adjustedMsg = switch (prevTurnId) {
      case (null) { msg };
      case (?tid) {
        switch (msg.agentMetadata) {
          case (null) { msg };
          case (?m) {
            {
              user = msg.user;
              text = msg.text;
              channel = msg.channel;
              ts = msg.ts;
              threadTs = msg.threadTs;
              isBotMessage = msg.isBotMessage;
              agentMetadata = ?{
                event_type = m.event_type;
                event_payload = {
                  parent_agent = m.event_payload.parent_agent;
                  parent_ts = m.event_payload.parent_ts;
                  parent_channel = m.event_payload.parent_channel;
                  turn_id = tid;
                };
              };
            };
          };
        };
      };
    };
    await MessageHandler.handle(adjustedMsg, ctx);
  };

  /// Like `testMessageHandlerBotBranch`, but uses `ctxWithOpenRouterOnlySecrets` (no Slack
  /// bot token) so the `postTerminationIfTokenAvailable` call is a no-op.
  ///
  /// Use this for non-deferred guard tests that verify termination logic (e.g.
  /// MAX_AGENT_ROUNDS delegation depth) without needing a cassette to handle the
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
    openRouterApiKey : Text,
    parentChannel : Text,
    parentTs : Text,
    delegationDepth : Nat,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    let ctx = TestHelpers.ctxWithOpenRouterOnlySecrets(slackUsers, testWorkspacesState, openRouterApiKey, [msg.channel]);
    let parentAuthCtx : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_SEEDED_PARENT";
      isPrimaryOwner = false;
      isOrgAdmin = false;
      adminWorkspaces = Set.empty<Nat>();
    };
    ChannelHistoryModel.addMessage(
      ctx.channelHistory,
      parentChannel,
      {
        ts = parentTs;
        userAuthContext = null;
        text = "seeded parent message";
        agentMetadata = null;
      },
      null,
    );
    ignore ChannelHistoryModel.updateMessageContext(
      ctx.channelHistory,
      parentChannel,
      parentTs,
      parentTs,
      ?parentAuthCtx,
    );
    // Seed a delegation chain in the session stores
    var prevTurnId : ?Text = null;
    var i = 0;
    while (i < delegationDepth) {
      let turn = SessionModel.createTurn(ctx.sessionStores, 0, null, prevTurnId, ?parentAuthCtx);
      SessionModel.completeTurn(ctx.sessionStores, turn.turnId, #succeeded, null, null);
      prevTurnId := ?turn.turnId;
      i += 1;
    };
    // Override turn_id only when turns were seeded; otherwise pass msg through unchanged.
    let adjustedMsg = switch (prevTurnId) {
      case (null) { msg };
      case (?tid) {
        switch (msg.agentMetadata) {
          case (null) { msg };
          case (?m) {
            {
              user = msg.user;
              text = msg.text;
              channel = msg.channel;
              ts = msg.ts;
              threadTs = msg.threadTs;
              isBotMessage = msg.isBotMessage;
              agentMetadata = ?{
                event_type = m.event_type;
                event_payload = {
                  parent_agent = m.event_payload.parent_agent;
                  parent_ts = m.event_payload.parent_ts;
                  parent_channel = m.event_payload.parent_channel;
                  turn_id = tid;
                };
              };
            };
          };
        };
      };
    };
    await MessageHandler.handle(adjustedMsg, ctx);
  };

  /// Like `testMessageHandlerWithSecrets`, but pre-seeds the context with BOTH a
  /// `unit-test-admin` (#_system(#admin)) and a `unit-test-custom` (#custom) agent.
  ///
  /// Use this variant for primary-agent resolution tests that reference `::unit-test-custom`
  /// explicitly.  Because `route(#custom, …)` returns a stub error without making any HTTP
  /// calls, these tests complete quickly with no cassette required.
  public shared ({ caller }) func testMessageHandlerWithCustomAgent(
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
    openRouterApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndCustom(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  /// Like `testMessageHandlerWithCustomAgent`, but uses `TestHelpers.ctxWithSecretsAndCustomNoOpenRouter`
  /// so the admin route short-circuits at key resolution (#err) without any HTTP outcall.
  ///
  /// Use for primary-agent fallback tests on a non-deferred actor where you only need
  /// to assert that the agent WAS resolved (i.e. primary_agent_skip is NOT emitted).
  public shared ({ caller }) func testMessageHandlerWithCustomAgentNoOpenRouter(
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
    ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, msg.channel);
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndCustomNoOpenRouter(slackUsers, testWorkspacesState, botToken, [msg.channel]));
  };

  /// Variant of testMessageHandlerWithSecrets designed for admin routing guard tests.
  ///
  /// @param adminChannelOverride  — `[channelId]` sets workspace 0's admin channel to
  ///                                that specific channel (for wrong-channel blocking tests).
  ///                                `[]` leaves workspace 0 with no admin channel
  ///                                (for null-adminChannelId blocking tests).
  ///
  /// Unlike testMessageHandlerWithSecrets, this function does NOT set workspace 0's
  /// admin channel to msg.channel. Use it when you want the guard to fire.
  public shared ({ caller }) func testMessageHandlerAdminChannelBlocked(
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
    openRouterApiKey : Text,
    adminChannelOverride : ?Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    switch (adminChannelOverride) {
      case (?chId) {
        ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, chId);
      };
      case (null) {}; // leave workspace 0 with no admin channel
    };
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, openRouterApiKey, [msg.channel]));
  };

  public shared ({ caller }) func testMessageDeletedHandler(
    deleted : {
      channel : Text;
      deletedTs : Text;
    }
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageDeletedHandler.handle(deleted, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    await MessageEditedHandler.handle(edited, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    await AssistantThreadHandler.handle(thread, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    await TeamJoinHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    await MemberJoinedChannelHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    await MemberLeftChannelHandler.handle(event, TestHelpers.emptyCtx(slackUsers, testWorkspacesState));
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
    adminWorkspaces : [Nat];
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
        let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
        {
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          adminWorkspaces = adminIds;
        };
      },
    );
  };

  /// Look up a specific Slack user by ID
  public query func getSlackUser(slackUserId : Text) : async ?SlackUserInfo {
    switch (SlackUserModel.lookupUser(slackUsers.cache, slackUserId)) {
      case (null) { null };
      case (?entry) {
        let adminIds = SlackUserModel.getAdminWorkspaceIds(entry);
        ?({
          slackUserId = entry.slackUserId;
          displayName = entry.displayName;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          isBot = entry.isBot;
          adminWorkspaces = adminIds;
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
        };
        let wsIdOpt : ?Nat = switch (e.changeType) {
          case (#workspaceAdminGranted(wsId)) { ?wsId };
          case (#workspaceAdminRevoked(wsId)) { ?wsId };
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
        adminWorkspaces = Set.empty<Nat>();
      },
      #manual,
    );
  };

  /// Seed a workspace admin channel membership for a user in the persistent state.
  /// The user must already exist in the cache (seed via seedSlackUser first).
  public shared ({ caller }) func seedWorkspaceMembership(
    slackUserId : Text,
    workspaceId : Nat,
  ) : async () {
    assert caller == parent;
    ignore SlackUserModel.joinAdminChannel(slackUsers, slackUserId, workspaceId, #manual);
  };

  /// Run the weekly reconciliation runner against the shared test cache and
  /// the pre-seeded test workspace state.
  ///
  /// @param token               Decrypted Slack bot token (or mock value)
  /// @param orgAdminChannelId   Optional org-admin channel ID — when provided, sets workspace 0's
  ///                            adminChannelId before the run so the runner treats it as the org-admin channel
  public shared ({ caller }) func testWeeklyReconciliationRunner(
    token : Text,
    orgAdminChannelId : ?Text,
  ) : async {
    #ok : WeeklyReconciliationRunner.ReconciliationSummary;
    #err : Text;
  } {
    assert caller == parent;
    // Set workspace 0's adminChannelId so the reconciliation runner treats it as the org-admin channel.
    switch (orgAdminChannelId) {
      case (null) {};
      case (?channelId) {
        ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, channelId);
      };
    };
    // Seed the token into testSecretsMap so the runner can resolve it.
    ignore SecretModel.storeSecret(testSecretsMap, TestHelpers.dummyKey, 0, #slackBotToken, token, { slackUserId = null; agentId = null; operation = "test" });
    await WeeklyReconciliationRunner.run(
      testSecretsKeyCache,
      testSecretsMap,
      slackUsers,
      testWorkspacesState,
    );
  };

  // ============================================
  // Timer Runner Test Methods
  // ============================================

  /// Run the clear-key-cache runner and apply the result to testKeyCache.
  /// Returns the cache size after the run.
  public shared ({ caller }) func testClearKeyCacheRunner() : async {
    #ok : Nat;
    #err : Text;
  } {
    assert caller == parent;
    switch (ClearKeyCacheRunner.run()) {
      case (#ok(cache)) {
        testKeyCache := cache;
        #ok(KeyDerivationService.getCacheSize(testKeyCache));
      };
      case (#err(e)) { #err(e) };
    };
  };

  /// Run the processed-events-cleanup runner against testEventStore.
  public shared ({ caller }) func testProcessedEventsCleanupRunner() : async {
    #ok;
    #err : Text;
  } {
    assert caller == parent;
    ProcessedEventsCleanupRunner.run(testEventStore);
  };

  /// Run the channel-history-prune runner against testChannelHistoryStore.
  public shared ({ caller }) func testChannelHistoryPruneRunner() : async {
    #ok;
    #err : Text;
  } {
    assert caller == parent;
    ChannelHistoryPruneRunner.run(testChannelHistoryStore);
  };

  /// Seed a message directly into testChannelHistoryStore for prune runner tests.
  /// The ts string format must be "SECONDS.MICROSECONDS" (e.g. "1700000000.000001").
  /// Pass null for threadTs to store as a top-level post.
  public shared ({ caller }) func testSeedChannelHistoryMessage(
    channelId : Text,
    ts : Text,
    threadTs : ?Text,
  ) : async () {
    assert caller == parent;
    ChannelHistoryModel.addMessage(
      testChannelHistoryStore,
      channelId,
      {
        ts;
        userAuthContext = null;
        text = "test message";
        agentMetadata = null;
      },
      threadTs,
    );
  };

  /// Returns the number of top-level timeline entries for the given channel
  /// in testChannelHistoryStore. Returns 0 if the channel does not exist.
  public shared query ({ caller }) func testGetChannelHistoryEntryCount(channelId : Text) : async Nat {
    assert caller == parent;
    switch (Map.get(testChannelHistoryStore, Text.compare, channelId)) {
      case (null) { 0 };
      case (?ch) { Map.size(ch.timeline) };
    };
  };

  // ============================================
  // Slack Adapter Test Methods
  // ============================================

  public shared query ({ caller }) func testSlackSignatureVerification(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : async Bool {
    assert caller == parent;
    SlackAdapter.verifySignature(signingSecret, signature, timestamp, body);
  };

  public shared query ({ caller }) func testSlackTimestampVerification(timestamp : Text) : async Bool {
    assert caller == parent;
    SlackAdapter.verifyTimestamp(timestamp);
  };

  // ============================================
  // Key Derivation Service Test Methods
  // ============================================

  /// Returns the current number of entries in the persistent test key cache.
  public shared query ({ caller }) func testGetKeyCacheSize() : async Nat {
    assert caller == parent;
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

  // ============================================
  // Tool Handler Test Methods
  // ============================================

  /// Test the SetWorkspaceAdminChannelHandler in isolation.
  ///
  /// @param args           JSON-encoded tool arguments (workspaceId + channelId).
  /// @param botToken       Slack bot token forwarded to SlackWrapper for channel verification.
  /// @param auth           Simplified auth context — builds UserAuthContext internally so
  ///                       tests do not need to serialise the full type over Candid.
  ///
  /// Note: the handler runs against the pre-seeded testWorkspacesState:
  ///   Workspace 0: Default (no channel anchors)
  ///   Workspace 1: adminChannelId = C_ADMIN_CHANNEL
  ///   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN
  public shared ({ caller }) func testSetWorkspaceAdminChannelHandler(
    args : Text,
    botToken : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    await SetWorkspaceAdminChannelHandler.handle(testWorkspacesState, uac, func(_ : Text) : ?Text { ?botToken }, args);
  };

  /// Test the CreateWorkspaceHandler in isolation.
  ///
  /// @param args      JSON-encoded tool arguments ({ name: string, channelId: string }).
  /// @param botToken  Slack bot token forwarded to SlackWrapper for channel verification.
  /// @param auth      Simplified auth context.
  ///
  /// Note: runs against the pre-seeded testWorkspacesState (workspaces 0, 1, 2).
  /// Workspaces created here persist within the same canister lifetime.
  public shared ({ caller }) func testCreateWorkspaceHandler(
    args : Text,
    botToken : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    await CreateWorkspaceHandler.handle(testWorkspacesState, testAgentRegistry, uac, func(_ : Text) : ?Text { ?botToken }, args);
  };

  /// Test the DeleteWorkspaceHandler in isolation.
  ///
  /// @param args  JSON-encoded tool arguments ({ workspaceId: number }).
  /// @param auth  Simplified auth context.
  ///
  /// Note: runs against the pre-seeded testWorkspacesState (workspaces 0, 1, 2).
  public shared ({ caller }) func testDeleteWorkspaceHandler(
    args : Text,
    triggerMessageText : ?Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    DeleteWorkspaceHandler.handle(testWorkspacesState, uac, triggerMessageText, args);
  };

  /// Test the ListWorkspacesHandler in isolation.
  ///
  /// @param args   JSON-encoded tool arguments (unused by this handler).
  ///
  /// Note: runs against the pre-seeded testWorkspacesState (workspaces 0, 1, 2).
  public shared ({ caller }) func testListWorkspacesHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListWorkspacesHandler.handle(testWorkspacesState, args);
  };

  // ============================================
  // Agent Handler Test Methods
  //
  // All agent handlers run against testAgentRegistry (starts empty).
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Build a UserAuthContext for agent handler tests.
  private func agentHandlerUac(isPrimaryOwner : Bool, isOrgAdmin : Bool) : SlackAuthMiddleware.UserAuthContext {
    {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner;
      isOrgAdmin;
      adminWorkspaces = Set.empty<Nat>();
    };
  };

  /// Test the RegisterAgentHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ name, category, llmModel?, secretsAllowed?, toolsDisallowed?, sources? }).
  /// @param auth  Simplified auth context.
  ///
  /// Agents registered here persist for the lifetime of this PocketIC canister
  /// so subsequent calls to testListAgentsHandler / testGetAgentHandler see them.
  public shared ({ caller }) func testRegisterAgentHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await RegisterAgentHandler.handle(testAgentRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args, null, null);
  };

  /// Directly seed a #_system(#admin) agent into testAgentRegistry without going through
  /// the create_workspace HTTP flow. Useful for unit tests that need a system admin agent.
  /// Returns the assigned agent ID.
  public shared ({ caller }) func testDirectSeedAdminAgent() : async Nat {
    assert caller == parent;
    switch (
      AgentModel.register(
        testAgentRegistry,
        0,
        #_system(#admin),
        {
          name = "test-admin";
          model = "openai/gpt-oss-120b";
          executionEngines = [#canister];
          allowedChannelIds = Set.empty<Text>();
          secrets = { allowed = []; overrides = [] };
        },
      )
    ) {
      case (#ok id) { id };
      case (#err _) { 999 };
    };
  };

  /// Test the ListAgentsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  public shared ({ caller }) func testListAgentsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListAgentsHandler.handle(testAgentRegistry, args);
  };

  /// Test the GetAgentHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ id } or { name }).
  public shared ({ caller }) func testGetAgentHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetAgentHandler.handle(testAgentRegistry, args);
  };

  /// Test the UpdateAgentHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ id, name?, category?, llmModel?, secretsAllowed?, toolsDisallowed?, sources? }).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testUpdateAgentHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await UpdateAgentHandler.handle(testAgentRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args, null);
  };

  /// Test the UnregisterAgentHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ id }).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testUnregisterAgentHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await UnregisterAgentHandler.handle(testAgentRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  // ============================================
  // MCP Tool Handler Test Methods
  //
  // All MCP handlers run against testMcpToolRegistry (starts empty).
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Test the RegisterMcpToolHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ name, serverId, description?, parameters?, remoteName? }).
  /// @param auth  Simplified auth context.
  ///
  /// Tools registered here persist for the lifetime of this PocketIC canister
  /// so subsequent calls to testListMcpToolsHandler see them.
  public shared ({ caller }) func testRegisterMcpToolHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await RegisterMcpToolHandler.handle(testMcpToolRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  /// Test the UnregisterMcpToolHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ name }).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testUnregisterMcpToolHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await UnregisterMcpToolHandler.handle(testMcpToolRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  /// Test the ListMcpToolsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  public shared ({ caller }) func testListMcpToolsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListMcpToolsHandler.handle(testMcpToolRegistry, args);
  };

  // ============================================
  // Secrets Handler Test Methods
  //
  // All secrets handlers run against testSecretsMap (starts empty).
  // testSecretsKeyCache is pre-seeded with the all-zeros dummy key for
  // workspaces 0, 1, and 2, avoiding live Schnorr calls.
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Test the StoreSecretHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId, secretId, secretValue }).
  /// @param auth  Simplified auth context.
  ///
  /// Secrets stored here persist for the lifetime of this PocketIC canister
  /// so subsequent calls to testGetWorkspaceSecretsHandler see them.
  public shared ({ caller }) func testStoreSecretHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    await StoreSecretHandler.handle(testSecretsMap, testSecretsKeyCache, testWorkspacesState, uac, args);
  };

  /// Test the GetWorkspaceSecretsHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId }).
  /// @param auth  Simplified auth context.
  public shared ({ caller }) func testGetWorkspaceSecretsHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    await GetWorkspaceSecretsHandler.handle(testSecretsMap, uac, args);
  };

  /// Test the DeleteSecretHandler in isolation.
  /// @param args  JSON-encoded tool arguments ({ workspaceId, secretId }).
  /// @param auth  Simplified auth context.
  public shared ({ caller }) func testDeleteSecretHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let adminWorkspaces = Set.empty<Nat>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Set.add(adminWorkspaces, Nat.compare, wsId);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      adminWorkspaces;
    };
    await DeleteSecretHandler.handle(testSecretsMap, uac, args);
  };

  // ============================================
  // Event Store Handler Test Methods
  //
  // All event store handlers run against testEventStore (starts empty).
  // Use testSeedFailedEvent to inject a failed event before calling the handlers.
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Seed a failed event into testEventStore for handler tests.
  /// Enqueues a minimal event then immediately marks it as failed with the given error.
  public shared ({ caller }) func testSeedFailedEvent(
    eventId : Text,
    errorMsg : Text,
  ) : async () {
    assert caller == parent;
    let event : NormalizedEventTypes.Event = {
      source = #slack;
      idempotencyKey = eventId;
      eventId = "slack_" # eventId;
      timestamp = 0;
      payload = #message({
        user = "U_TEST";
        text = "test";
        channel = "C_TEST";
        ts = "1700000000.000001";
        threadTs = null;
        isBotMessage = false;
        agentMetadata = null;
      });
      enqueuedAt = 0;
      claimedAt = null;
      processedAt = null;
      failedAt = null;
      failedError = "";
      processingLog = [];
    };
    ignore EventStoreModel.enqueue(testEventStore, event);
    EventStoreModel.markFailed(testEventStore, "slack_" # eventId, errorMsg);
  };

  /// Seed a processed event into testEventStore for cleanup runner tests.
  /// Enqueues a minimal event then immediately marks it as processed.
  /// The processedAt timestamp is stamped with Time.now() inside EventStoreModel,
  /// so call this while pic.setTime() is set to the desired past/present time.
  public shared ({ caller }) func testSeedProcessedEvent(eventId : Text) : async () {
    assert caller == parent;
    let event : NormalizedEventTypes.Event = {
      source = #slack;
      idempotencyKey = eventId;
      eventId = "slack_" # eventId;
      timestamp = 0;
      payload = #message({
        user = "U_TEST";
        text = "test";
        channel = "C_TEST";
        ts = "1700000000.000001";
        threadTs = null;
        isBotMessage = false;
        agentMetadata = null;
      });
      enqueuedAt = 0;
      claimedAt = null;
      processedAt = null;
      failedAt = null;
      failedError = "";
      processingLog = [];
    };
    ignore EventStoreModel.enqueue(testEventStore, event);
    EventStoreModel.markProcessed(testEventStore, "slack_" # eventId, []);
  };

  /// Test the GetEventStoreStatsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testGetEventStoreStatsHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await GetEventStoreStatsHandler.handle(testEventStore, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  /// Test the GetFailedEventsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testGetFailedEventsHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await GetFailedEventsHandler.handle(testEventStore, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  /// Test the DeleteFailedEventsHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ eventId? }).
  /// @param auth Simplified auth context.
  public shared ({ caller }) func testDeleteFailedEventsHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
    },
  ) : async Text {
    assert caller == parent;
    await DeleteFailedEventsHandler.handle(testEventStore, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
  };

  /// Test the SlackEventIntakeService in isolation.
  /// Parses the raw JSON body, normalizes and enqueues the event into testEventStore.
  /// Returns a plain-text discriminant:
  ///   "enqueued:<eventId>" — event was normalized and stored
  ///   "duplicate"          — event already present in the store
  ///   "skipped:<reason>"   — event was recognized but intentionally dropped
  ///   "notEventCallback"   — envelope is not an event_callback
  ///   "parseError:<msg>"   — JSON parsing or validation failed
  public shared ({ caller }) func testSlackEventIntakeService(body : Text) : async Text {
    assert caller == parent;
    switch (SlackEventIntakeService.processEventBody(testEventStore, body)) {
      case (#enqueued(eventId)) { "enqueued:" # eventId };
      case (#duplicate) { "duplicate" };
      case (#skipped(reason)) { "skipped:" # reason };
      case (#notEventCallback) { "notEventCallback" };
      case (#parseError(msg)) { "parseError:" # msg };
    };
  };
};
