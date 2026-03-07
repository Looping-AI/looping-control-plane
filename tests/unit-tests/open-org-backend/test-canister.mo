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
import SetWorkspaceAdminChannelHandler "../../../src/open-org-backend/tools/handlers/workspaces/set-workspace-admin-channel-handler";
import SetWorkspaceMemberChannelHandler "../../../src/open-org-backend/tools/handlers/workspaces/set-workspace-member-channel-handler";
import CreateWorkspaceHandler "../../../src/open-org-backend/tools/handlers/workspaces/create-workspace-handler";
import ListWorkspacesHandler "../../../src/open-org-backend/tools/handlers/workspaces/list-workspaces-handler";
import CreateMetricHandler "../../../src/open-org-backend/tools/handlers/metrics/create-metric-handler";
import UpdateMetricHandler "../../../src/open-org-backend/tools/handlers/metrics/update-metric-handler";
import GetMetricHandler "../../../src/open-org-backend/tools/handlers/metrics/get-metric-handler";
import ListMetricsHandler "../../../src/open-org-backend/tools/handlers/metrics/list-metrics-handler";
import DeleteMetricHandler "../../../src/open-org-backend/tools/handlers/metrics/delete-metric-handler";
import RecordMetricDatapointHandler "../../../src/open-org-backend/tools/handlers/metrics/record-metric-datapoint-handler";
import GetMetricDatapointsHandler "../../../src/open-org-backend/tools/handlers/metrics/get-metric-datapoints-handler";
import GetLatestMetricDatapointHandler "../../../src/open-org-backend/tools/handlers/metrics/get-latest-metric-datapoint-handler";
import SaveValueStreamHandler "../../../src/open-org-backend/tools/handlers/value-streams/save-value-stream-handler";
import SavePlanHandler "../../../src/open-org-backend/tools/handlers/save-plan-handler";
import ListValueStreamsHandler "../../../src/open-org-backend/tools/handlers/value-streams/list-value-streams-handler";
import GetValueStreamHandler "../../../src/open-org-backend/tools/handlers/value-streams/get-value-stream-handler";
import DeleteValueStreamHandler "../../../src/open-org-backend/tools/handlers/value-streams/delete-value-stream-handler";
import CreateObjectiveHandler "../../../src/open-org-backend/tools/handlers/objectives/create-objective-handler";
import UpdateObjectiveHandler "../../../src/open-org-backend/tools/handlers/objectives/update-objective-handler";
import ArchiveObjectiveHandler "../../../src/open-org-backend/tools/handlers/objectives/archive-objective-handler";
import RecordObjectiveDatapointHandler "../../../src/open-org-backend/tools/handlers/objectives/record-objective-datapoint-handler";
import AddImpactReviewHandler "../../../src/open-org-backend/tools/handlers/objectives/add-impact-review-handler";
import ListObjectivesHandler "../../../src/open-org-backend/tools/handlers/objectives/list-objectives-handler";
import GetObjectiveHandler "../../../src/open-org-backend/tools/handlers/objectives/get-objective-handler";
import GetObjectiveHistoryHandler "../../../src/open-org-backend/tools/handlers/objectives/get-objective-history-handler";
import AddObjectiveDatapointCommentHandler "../../../src/open-org-backend/tools/handlers/objectives/add-objective-datapoint-comment-handler";
import GetImpactReviewsHandler "../../../src/open-org-backend/tools/handlers/objectives/get-impact-reviews-handler";
import RegisterAgentHandler "../../../src/open-org-backend/tools/handlers/agents/register-agent-handler";
import ListAgentsHandler "../../../src/open-org-backend/tools/handlers/agents/list-agents-handler";
import GetAgentHandler "../../../src/open-org-backend/tools/handlers/agents/get-agent-handler";
import UpdateAgentHandler "../../../src/open-org-backend/tools/handlers/agents/update-agent-handler";
import UnregisterAgentHandler "../../../src/open-org-backend/tools/handlers/agents/unregister-agent-handler";
import RegisterMcpToolHandler "../../../src/open-org-backend/tools/handlers/mcp/register-mcp-tool-handler";
import UnregisterMcpToolHandler "../../../src/open-org-backend/tools/handlers/mcp/unregister-mcp-tool-handler";
import ListMcpToolsHandler "../../../src/open-org-backend/tools/handlers/mcp/list-mcp-tools-handler";
import StoreSecretHandler "../../../src/open-org-backend/tools/handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "../../../src/open-org-backend/tools/handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "../../../src/open-org-backend/tools/handlers/secrets/delete-secret-handler";
import GetEventStoreStatsHandler "../../../src/open-org-backend/tools/handlers/events/get-event-store-stats-handler";
import GetFailedEventsHandler "../../../src/open-org-backend/tools/handlers/events/get-failed-events-handler";
import DeleteFailedEventsHandler "../../../src/open-org-backend/tools/handlers/events/delete-failed-events-handler";
import WeeklyReconciliationService "../../../src/open-org-backend/services/weekly-reconciliation-service";
import ValueStreamModel "../../../src/open-org-backend/models/value-stream-model";
import ObjectiveModel "../../../src/open-org-backend/models/objective-model";
import MetricModel "../../../src/open-org-backend/models/metric-model";
import ConversationModel "../../../src/open-org-backend/models/conversation-model";
import SlackUserModel "../../../src/open-org-backend/models/slack-user-model";
import SlackAuthMiddleware "../../../src/open-org-backend/middleware/slack-auth-middleware";
import WorkspaceModel "../../../src/open-org-backend/models/workspace-model";
import AgentModel "../../../src/open-org-backend/models/agent-model";
import McpToolRegistry "../../../src/open-org-backend/tools/mcp-tool-registry";
import KeyDerivationService "../../../src/open-org-backend/services/key-derivation-service";
import SecretModel "../../../src/open-org-backend/models/secret-model";
import EventStoreModel "../../../src/open-org-backend/models/event-store-model";
import Types "../../../src/open-org-backend/types";
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

  // Persistent metric state for handler tests. Starts empty; tests
  // create metrics through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  var testMetricsRegistry = MetricModel.emptyRegistry();
  var testMetricDatapoints = MetricModel.emptyDatapoints();

  // Persistent value stream state for handler tests. Workspace 0 is pre-initialised
  // so create/list/get/delete tests can run directly against it.
  var testValueStreamsMap = do {
    let m = ValueStreamModel.emptyValueStreamsMap();
    Map.add(m, Nat.compare, 0, ValueStreamModel.emptyWorkspaceState());
    m;
  };
  let testValueStreamWorkspaceId : Nat = 0;

  // Per-workspace objectives map for delete handler cleanup tests.
  var testWorkspaceObjectivesMap = ObjectiveModel.emptyWorkspaceObjectivesMap();

  // Agent registry state for agent handler tests. Starts empty; tests
  // register agents through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  var testAgentRegistry = AgentModel.emptyState();

  // MCP tool registry state for MCP handler tests. Starts empty; tests
  // register tools through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  var testMcpToolRegistry = McpToolRegistry.empty();

  // Secrets map and key cache for secrets handler tests. Starts empty; tests
  // store/delete secrets through handler calls and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  // The key cache is pre-seeded with the all-zeros dummy key for workspaces 0, 1, 2
  // to avoid live Schnorr calls during unit tests.
  var testSecretsMap = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
  var testSecretsKeyCache : KeyDerivationService.KeyCache = Map.fromArray<Nat, [Nat8]>(
    [(0, TestHelpers.dummyKey), (1, TestHelpers.dummyKey), (2, TestHelpers.dummyKey)],
    Nat.compare,
  );

  // Event store state for event handler tests. Starts empty; tests seed events
  // through the testSeedFailedEvent helper and state persists within a single
  // canister lifetime (but each test creates a fresh PocketIC canister).
  var testEventStore = EventStoreModel.empty();

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
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, groqApiKey));
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
    let ctx = TestHelpers.ctxWithSecrets(slackUsers, testWorkspacesState, botToken, groqApiKey);
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
    let ctx = TestHelpers.ctxWithGroqOnlySecrets(slackUsers, testWorkspacesState, groqApiKey);
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
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndResearch(slackUsers, testWorkspacesState, botToken, groqApiKey));
  };

  /// Like `testMessageHandlerWithResearchAgent`, but uses `TestHelpers.ctxWithSecretsAndResearchNoGroq`
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
    await MessageHandler.handle(msg, TestHelpers.ctxWithSecretsAndResearchNoGroq(slackUsers, testWorkspacesState, botToken));
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
  /// @param orgAdminChannelId   Optional org-admin channel ID — when provided, sets workspace 0's
  ///                            adminChannelId before the run so the service treats it as the org-admin channel
  public shared ({ caller }) func testWeeklyReconciliation(
    token : Text,
    orgAdminChannelId : ?Text,
  ) : async WeeklyReconciliationService.ReconciliationSummary {
    assert caller == parent;
    // Set workspace 0's adminChannelId so the reconciliation service treats it as the org-admin channel.
    switch (orgAdminChannelId) {
      case (null) {};
      case (?channelId) {
        ignore WorkspaceModel.setAdminChannel(testWorkspacesState, 0, channelId);
      };
    };
    await WeeklyReconciliationService.run(
      token,
      slackUsers,
      testWorkspacesState,
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
  ///   Workspace 1: adminChannelId = C_ADMIN_CHANNEL, memberChannelId = C_MEMBER_CHANNEL
  ///   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN, memberChannelId = C_ROUND_TRIP_MEMBER
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
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
    };
    await SetWorkspaceAdminChannelHandler.handle(testWorkspacesState, uac, botToken, args);
  };

  /// Test the CreateWorkspaceHandler in isolation.
  ///
  /// @param args   JSON-encoded tool arguments ({ name: string }).
  /// @param auth   Simplified auth context.
  ///
  /// Note: runs against the pre-seeded testWorkspacesState (workspaces 0, 1, 2).
  /// Workspaces created here persist within the same canister lifetime.
  public shared ({ caller }) func testCreateWorkspaceHandler(
    args : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
    };
    await CreateWorkspaceHandler.handle(testWorkspacesState, uac, args);
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

  /// Test the SetWorkspaceMemberChannelHandler in isolation.
  ///
  /// @param args       JSON-encoded tool arguments (workspaceId + channelId).
  /// @param botToken   Slack bot token forwarded to SlackWrapper for channel verification.
  /// @param auth       Simplified auth context.
  ///
  /// Note: the handler runs against the pre-seeded testWorkspacesState:
  ///   Workspace 0: Default (no channel anchors)
  ///   Workspace 1: adminChannelId = C_ADMIN_CHANNEL, memberChannelId = C_MEMBER_CHANNEL
  ///   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN, memberChannelId = C_ROUND_TRIP_MEMBER
  public shared ({ caller }) func testSetWorkspaceMemberChannelHandler(
    args : Text,
    botToken : Text,
    auth : {
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      workspaceAdminFor : ?Nat;
    },
  ) : async Text {
    assert caller == parent;
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
    };
    await SetWorkspaceMemberChannelHandler.handle(testWorkspacesState, uac, botToken, args);
  };

  // ============================================
  // Metric Handler Test Methods
  // ============================================

  /// Test the CreateMetricHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ name, description, unit, retentionDays }).
  public shared ({ caller }) func testCreateMetricHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await CreateMetricHandler.handle(testMetricsRegistry, args);
  };

  /// Test the UpdateMetricHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId, name?, description?, unit?, retentionDays? }).
  public shared ({ caller }) func testUpdateMetricHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await UpdateMetricHandler.handle(testMetricsRegistry, args);
  };

  /// Test the GetMetricHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId }).
  public shared ({ caller }) func testGetMetricHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetMetricHandler.handle(testMetricsRegistry, args);
  };

  /// Test the ListMetricsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  public shared ({ caller }) func testListMetricsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListMetricsHandler.handle(testMetricsRegistry, args);
  };

  /// Test the DeleteMetricHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId }).
  public shared ({ caller }) func testDeleteMetricHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await DeleteMetricHandler.handle(testMetricsRegistry, testMetricDatapoints, args);
  };

  /// Test the RecordMetricDatapointHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId, value, sourceType?, sourceLabel? }).
  public shared ({ caller }) func testRecordMetricDatapointHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await RecordMetricDatapointHandler.handle(testMetricsRegistry, testMetricDatapoints, args);
  };

  /// Test the GetMetricDatapointsHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId, since?, limit? }).
  public shared ({ caller }) func testGetMetricDatapointsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetMetricDatapointsHandler.handle(testMetricsRegistry, testMetricDatapoints, args);
  };

  /// Test the GetLatestMetricDatapointHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ metricId }).
  public shared ({ caller }) func testGetLatestMetricDatapointHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetLatestMetricDatapointHandler.handle(testMetricsRegistry, testMetricDatapoints, args);
  };

  // ============================================
  // Value Stream Handler Test Methods
  // ============================================

  /// Test the SaveValueStreamHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ id?, name, problem, goal, activate? }).
  public shared ({ caller }) func testSaveValueStreamHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await SaveValueStreamHandler.handle(testValueStreamWorkspaceId, testValueStreamsMap, args);
  };

  /// Test the SavePlanHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, summary, currentState, targetState, steps, risks, resources }).
  public shared ({ caller }) func testSavePlanHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await SavePlanHandler.handle(testValueStreamWorkspaceId, testValueStreamsMap, args);
  };

  /// Test the ListValueStreamsHandler in isolation.
  /// @param args JSON-encoded tool arguments (unused by this handler).
  public shared ({ caller }) func testListValueStreamsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListValueStreamsHandler.handle(testValueStreamWorkspaceId, testValueStreamsMap, args);
  };

  /// Test the GetValueStreamHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId }).
  public shared ({ caller }) func testGetValueStreamHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetValueStreamHandler.handle(testValueStreamWorkspaceId, testValueStreamsMap, args);
  };

  /// Test the DeleteValueStreamHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId }).
  public shared ({ caller }) func testDeleteValueStreamHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await DeleteValueStreamHandler.handle(testValueStreamWorkspaceId, testValueStreamsMap, testWorkspaceObjectivesMap, args);
  };

  // ============================================
  // Objective Handler Test Methods
  //
  // All objective handlers run against testWorkspaceObjectivesMap
  // (workspace ID 0, shared with value-stream cleanup tests).
  // Each test creates a fresh PocketIC canister so there is no
  // cross-test state leakage.
  // ============================================

  /// Test the CreateObjectiveHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, name, objectiveType, metricIds, computation, targetType, ... }).
  public shared ({ caller }) func testCreateObjectiveHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await CreateObjectiveHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the ListObjectivesHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId }).
  public shared ({ caller }) func testListObjectivesHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ListObjectivesHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the GetObjectiveHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId }).
  public shared ({ caller }) func testGetObjectiveHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetObjectiveHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the UpdateObjectiveHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId, name?, description?, ... }).
  public shared ({ caller }) func testUpdateObjectiveHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await UpdateObjectiveHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the ArchiveObjectiveHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId }).
  public shared ({ caller }) func testArchiveObjectiveHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await ArchiveObjectiveHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the RecordObjectiveDatapointHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId, value, ... }).
  public shared ({ caller }) func testRecordObjectiveDatapointHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await RecordObjectiveDatapointHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the GetObjectiveHistoryHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId }).
  public shared ({ caller }) func testGetObjectiveHistoryHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetObjectiveHistoryHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the AddObjectiveDatapointCommentHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId, historyIndex, message, author? }).
  public shared ({ caller }) func testAddObjectiveDatapointCommentHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await AddObjectiveDatapointCommentHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the AddImpactReviewHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId, perceivedImpact, comment?, author? }).
  public shared ({ caller }) func testAddImpactReviewHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await AddImpactReviewHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
  };

  /// Test the GetImpactReviewsHandler in isolation.
  /// @param args JSON-encoded tool arguments ({ valueStreamId, objectiveId }).
  public shared ({ caller }) func testGetImpactReviewsHandler(
    args : Text
  ) : async Text {
    assert caller == parent;
    await GetImpactReviewsHandler.handle(testValueStreamWorkspaceId, testWorkspaceObjectivesMap, args);
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
      workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
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
    await RegisterAgentHandler.handle(testAgentRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
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
    await UpdateAgentHandler.handle(testAgentRegistry, agentHandlerUac(auth.isPrimaryOwner, auth.isOrgAdmin), args);
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
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
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
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
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
    let workspaceScopes = Map.empty<Nat, SlackUserModel.WorkspaceScope>();
    switch (auth.workspaceAdminFor) {
      case (?wsId) {
        Map.add(workspaceScopes, Nat.compare, wsId, #admin);
      };
      case (null) {};
    };
    let uac : SlackAuthMiddleware.UserAuthContext = {
      slackUserId = "U_TEST_USER";
      isPrimaryOwner = auth.isPrimaryOwner;
      isOrgAdmin = auth.isOrgAdmin;
      workspaceScopes;
      roundCount = 0;
      forceTerminated = false;
      parentRef = null;
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
};
