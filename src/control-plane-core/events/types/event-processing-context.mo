/// Event Processing Context
/// Carries the actor-level state that event handlers need to do real work
/// (LLM calls, Slack replies, etc.).
///
/// Defined here — separate from event-router.mo — so that handler modules can
/// import this type directly without creating a circular dependency
/// (event-router.mo → handlers → event-router.mo).
///
/// event-router.mo re-exports this as EventRouter.EventProcessingContext
/// so callers (like main.mo) that already import EventRouter don't need an
/// extra import.

import Map "mo:core/Map";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ChannelHistoryModel "../../models/channel-history-model";
import McpToolRegistry "../../tools/mcp-tool-registry";
import AgentModel "../../models/agent-model";
import ValueStreamModel "../../models/value-stream-model";
import ObjectiveModel "../../models/objective-model";
import MetricModel "../../models/metric-model";
import SlackUserModel "../../models/slack-user-model";
import WorkspaceModel "../../models/workspace-model";
import EventStoreModel "../../models/event-store-model";
import SessionModel "../../models/session-model";

module {

  /// All actor-level state required for a handler to process an event end-to-end.
  ///
  /// Mutable values (Maps, Lists) are passed by reference — mutations made inside
  /// a handler (e.g. appending to adminConversations) are visible to the actor
  /// without any explicit write-back.
  ///
  /// The handler is responsible for scoping org-wide maps down to the relevant
  /// workspace before passing data into lower-level services/orchestrators.
  public type EventProcessingContext = {
    /// Encrypted secrets and audit logs for all workspaces
    secrets : SecretModel.SecretsState;
    /// Async key-derivation cache — pass to KeyDerivationService.getOrDeriveKey
    keyCache : KeyDerivationService.KeyCache;
    /// Channel history store (channel-keyed Slack message timeline) — handlers call
    /// ChannelHistoryModel to add/update/delete messages; the event-driven path is
    /// the only write surface.
    channelHistory : ChannelHistoryModel.ChannelHistoryStore;
    /// MCP tool registry (org-wide)
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState;
    /// Global agent registry — used to resolve the active agent for a given category
    agentRegistry : AgentModel.AgentRegistryState;
    /// Value stream state per workspace — scope to workspaceId before use
    workspaceValueStreams : Map.Map<Nat, ValueStreamModel.WorkspaceValueStreamsState>;
    /// Objectives per workspace — scope to workspaceId before use
    workspaceObjectives : Map.Map<Nat, ObjectiveModel.WorkspaceObjectivesMap>;
    /// Org-level metric registry
    metricsRegistry : MetricModel.MetricsRegistryState;
    /// Org-level metric datapoints store
    metricDatapoints : MetricModel.MetricDatapointsStore;
    /// Slack user state (cache + access change log) — handlers for membership events mutate this directly
    slackUsers : SlackUserModel.SlackUserState;
    /// Workspace channel anchors — used to resolve channel IDs to workspace scopes
    workspaces : WorkspaceModel.WorkspacesState;
    /// Event store — passed to the org-admin agent for event queue management tools
    eventStore : EventStoreModel.EventStoreState;
    /// Agent session stores (sessions, turns, traces)
    sessionStores : SessionModel.SessionStores;
  };
};
