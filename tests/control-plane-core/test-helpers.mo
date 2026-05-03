import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Nat "mo:core/Nat";

import AgentModel "../../src/control-plane-core/models/agent-model";
import ChannelHistoryModel "../../src/control-plane-core/models/channel-history-model";
import ExecutionEnvelopeModel "../../src/control-plane-core/models/execution-envelope-model";
import SecretModel "../../src/control-plane-core/models/secret-model";
import SlackUserModel "../../src/control-plane-core/models/slack-user-model";
import WorkspaceModel "../../src/control-plane-core/models/workspace-model";
import EventProcessingContextTypes "../../src/control-plane-core/events/types/event-processing-context";
import EventStoreModel "../../src/control-plane-core/models/event-store-model";
import SessionModel "../../src/control-plane-core/models/session-model";
import InternalEngine "../../src/internal-engine/main";
import WorkflowCatalogModel "../../src/control-plane-core/models/workflow-catalog-model";
import ApprovalModel "../../src/control-plane-core/models/approval-model";

// ============================================
// Test Helpers
// ============================================

module {

  // ============================================
  // Constants
  // ============================================

  /// The deterministic 32-byte all-zeros key used for every workspace in unit tests.
  /// Seeding keyCache with this key avoids live Schnorr threshold-key calls.
  public let dummyKey : [Nat8] = [
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

  // ============================================
  // Context Builders
  // ============================================

  /// Creates an empty EventProcessingContext suitable for unit tests.
  /// Secrets are not populated so handlers that require them will return graceful
  /// error steps rather than crashing.
  public func emptyCtx(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
  ) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    {
      secrets = SecretModel.initState();
      keyCache;
      channelHistory = ChannelHistoryModel.empty();
      agentRegistry = AgentModel.emptyState();
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
      sessionStores = SessionModel.emptyStores();
      envelopeState = ExecutionEnvelopeModel.emptyState();
      internalEngine = actor "aaaaa-aa" : InternalEngine.InternalEngine; // sentinel: never called in these tests
      catalogState = WorkflowCatalogModel.empty();
      approvalState = ApprovalModel.emptyState();
    };
  };

  /// Creates an EventProcessingContext pre-seeded with a Slack bot token and an OpenRouter
  /// API key, both encrypted with the deterministic dummy key used across unit tests.
  /// This lets message-handler tests reach the Slack-posting code path without live
  /// Schnorr key derivation or a real secret-store call.
  ///
  /// Secrets are stored for workspace IDs 0, 1, and 42.
  public func ctxWithSecrets(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    botToken : Text,
    openRouterApiKey : Text,
    channelIds : [Text],
  ) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    let secrets = SecretModel.initState();
    for (wsId in [0, 1, 42].vals()) {
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #slackBotToken, botToken, { slackUserId = null; agentId = null; operation = "test" });
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #openRouterApiKey, openRouterApiKey, { slackUserId = null; agentId = null; operation = "test" });
    };
    // Register an admin agent permitted to access openRouterApiKey for workspaces 0, 1, and 42
    let registry = AgentModel.emptyState();
    ignore AgentModel.register(
      registry,
      0,
      #_system(#admin),
      {
        name = "unit-test-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = Set.fromArray(channelIds, Text.compare);
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    {
      secrets;
      keyCache;
      channelHistory = ChannelHistoryModel.empty();
      agentRegistry = registry;
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
      sessionStores = SessionModel.emptyStores();
      envelopeState = ExecutionEnvelopeModel.emptyState();
      internalEngine = actor "aaaaa-aa" : InternalEngine.InternalEngine; // sentinel: never called in these tests
      catalogState = WorkflowCatalogModel.empty();
      approvalState = ApprovalModel.emptyState();
    };
  };

  /// Like `ctxWithSecrets`, but stores the OpenRouter API key ONLY — no Slack bot token.
  ///
  /// Use this for guard tests (e.g. MAX_AGENT_ROUNDS, force-termination guards) that
  /// run on a non-deferred actor without cassette support.  When there is no
  /// `#slackBotToken` secret for the workspace, `resolveWorkspaceBotToken` returns
  /// null so `postTerminationIfTokenAvailable` is a no-op and no outgoing HTTPS call
  /// is attempted.  This avoids the pending-outcall problem in non-cassette tests.
  public func ctxWithOpenRouterOnlySecrets(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    openRouterApiKey : Text,
    channelIds : [Text],
  ) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    let secrets = SecretModel.initState();
    for (wsId in [0, 1, 42].vals()) {
      // NOTE: #slackBotToken intentionally absent — keeps postTerminationPrompt a no-op.
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #openRouterApiKey, openRouterApiKey, { slackUserId = null; agentId = null; operation = "test" });
    };
    let registry = AgentModel.emptyState();
    ignore AgentModel.register(
      registry,
      0,
      #_system(#admin),
      {
        name = "unit-test-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = Set.fromArray(channelIds, Text.compare);
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    {
      secrets;
      keyCache;
      channelHistory = ChannelHistoryModel.empty();
      agentRegistry = registry;
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
      sessionStores = SessionModel.emptyStores();
      envelopeState = ExecutionEnvelopeModel.emptyState();
      internalEngine = actor "aaaaa-aa" : InternalEngine.InternalEngine; // sentinel: never called in these tests
      catalogState = WorkflowCatalogModel.empty();
      approvalState = ApprovalModel.emptyState();
    };
  };

  /// Like `ctxWithSecrets`, but also registers a `unit-test-custom` agent with
  /// `#custom` category alongside the existing `unit-test-admin`.
  ///
  /// Use this context when a test needs to exercise primary agent resolution via
  /// an explicit `::unit-test-custom` reference.
  public func ctxWithSecretsAndCustom(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    botToken : Text,
    openRouterApiKey : Text,
    channelIds : [Text],
  ) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    let secrets = SecretModel.initState();
    for (wsId in [0, 1, 42].vals()) {
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #slackBotToken, botToken, { slackUserId = null; agentId = null; operation = "test" });
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #openRouterApiKey, openRouterApiKey, { slackUserId = null; agentId = null; operation = "test" });
    };
    let registry = AgentModel.emptyState();
    let allowedChannels = Set.fromArray(channelIds, Text.compare);
    // Admin agent (same as ctxWithSecrets)
    ignore AgentModel.register(
      registry,
      0,
      #_system(#admin),
      {
        name = "unit-test-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = allowedChannels;
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    // Custom agent — no real secret needed; route(#custom) returns a stub error
    // without making any HTTP calls, so a dummy secret entry is sufficient.
    ignore AgentModel.register(
      registry,
      0,
      #custom,
      {
        name = "unit-test-custom";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = allowedChannels;
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    {
      secrets;
      keyCache;
      channelHistory = ChannelHistoryModel.empty();
      agentRegistry = registry;
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
      sessionStores = SessionModel.emptyStores();
      envelopeState = ExecutionEnvelopeModel.emptyState();
      internalEngine = actor "aaaaa-aa" : InternalEngine.InternalEngine; // sentinel: never called in these tests
      catalogState = WorkflowCatalogModel.empty();
      approvalState = ApprovalModel.emptyState();
    };
  };

  /// Like `ctxWithSecretsAndCustom`, but does NOT seed an OpenRouter API key secret.
  /// When the admin route tries to decrypt the openRouterApiKey it finds null and returns
  /// #err immediately, without issuing any HTTPS outcall.
  ///
  /// Use for non-deferred primary-agent resolution tests that need to verify the
  /// fallback-to-admin path without triggering a live (or cassette-dependent) LLM call.
  public func ctxWithSecretsAndCustomNoOpenRouter(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    botToken : Text,
    channelIds : [Text],
  ) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    let secrets = SecretModel.initState();
    for (wsId in [0, 1, 42].vals()) {
      // NOTE: #openRouterApiKey intentionally absent — keeps admin route a sync no-op.
      ignore SecretModel.storeSecret(secrets, dummyKey, wsId, #slackBotToken, botToken, { slackUserId = null; agentId = null; operation = "test" });
    };
    let registry = AgentModel.emptyState();
    let allowedChannels = Set.fromArray(channelIds, Text.compare);
    ignore AgentModel.register(
      registry,
      0,
      #_system(#admin),
      {
        name = "unit-test-admin";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = allowedChannels;
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    ignore AgentModel.register(
      registry,
      0,
      #custom,
      {
        name = "unit-test-custom";
        model = "openai/gpt-oss-120b";
        workflowEngines = [#canister];
        allowedChannelIds = allowedChannels;
        secrets = {
          allowed = [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)];
          overrides = [];
        };
      },
    );
    {
      secrets;
      keyCache;
      channelHistory = ChannelHistoryModel.empty();
      agentRegistry = registry;
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
      sessionStores = SessionModel.emptyStores();
      envelopeState = ExecutionEnvelopeModel.emptyState();
      internalEngine = actor "aaaaa-aa" : InternalEngine.InternalEngine; // sentinel: never called in these tests
      catalogState = WorkflowCatalogModel.empty();
      approvalState = ApprovalModel.emptyState();
    };
  };

};
