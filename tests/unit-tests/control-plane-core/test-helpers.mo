import Map "mo:core/Map";
import Nat "mo:core/Nat";

import AgentModel "../../../src/control-plane-core/models/agent-model";
import ConversationModel "../../../src/control-plane-core/models/conversation-model";
import MetricModel "../../../src/control-plane-core/models/metric-model";
import McpToolRegistry "../../../src/control-plane-core/tools/mcp-tool-registry";
import ObjectiveModel "../../../src/control-plane-core/models/objective-model";
import SecretModel "../../../src/control-plane-core/models/secret-model";
import SlackUserModel "../../../src/control-plane-core/models/slack-user-model";
import ValueStreamModel "../../../src/control-plane-core/models/value-stream-model";
import WorkspaceModel "../../../src/control-plane-core/models/workspace-model";
import EventProcessingContextTypes "../../../src/control-plane-core/events/types/event-processing-context";
import EventStoreModel "../../../src/control-plane-core/models/event-store-model";
import Types "../../../src/control-plane-core/types";

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
      conversationStore = ConversationModel.empty();
      mcpToolRegistry = McpToolRegistry.empty();
      agentRegistry = AgentModel.emptyState();
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers;
      workspaces;
      eventStore = EventStoreModel.empty();
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
      "unit-test-admin",
      0,
      #admin,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
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
      workspaces;
      eventStore = EventStoreModel.empty();
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
      "unit-test-admin",
      0,
      #admin,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
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
      workspaces;
      eventStore = EventStoreModel.empty();
    };
  };

  /// Like `ctxWithSecrets`, but also registers a `unit-test-research` agent with
  /// `#research` category alongside the existing `unit-test-admin`.
  ///
  /// Use this context when a test needs to exercise primary agent resolution via
  /// an explicit `::unit-test-research` reference.
  public func ctxWithSecretsAndResearch(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    botToken : Text,
    openRouterApiKey : Text,
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
    // Admin agent (same as ctxWithSecrets)
    ignore AgentModel.register(
      "unit-test-admin",
      0,
      #admin,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    // Research agent — no real secret needed; route(#research) returns a stub error
    // without making any HTTP calls, so a dummy secret entry is sufficient.
    ignore AgentModel.register(
      "unit-test-research",
      0,
      #research,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
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
      workspaces;
      eventStore = EventStoreModel.empty();
    };
  };

  /// Like `ctxWithSecretsAndResearch`, but does NOT seed an OpenRouter API key secret.
  /// When the admin route tries to decrypt the openRouterApiKey it finds null and returns
  /// #err immediately, without issuing any HTTPS outcall.
  ///
  /// Use for non-deferred primary-agent resolution tests that need to verify the
  /// fallback-to-admin path without triggering a live (or cassette-dependent) LLM call.
  public func ctxWithSecretsAndResearchNoOpenRouter(
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    botToken : Text,
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
    ignore AgentModel.register(
      "unit-test-admin",
      0,
      #admin,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      registry,
    );
    ignore AgentModel.register(
      "unit-test-research",
      0,
      #research,
      #openRouter(#gpt_oss_120b),
      #api,
      [(0, #openRouterApiKey), (1, #openRouterApiKey), (42, #openRouterApiKey)],
      [],
      [],
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
      workspaces;
      eventStore = EventStoreModel.empty();
    };
  };

};
