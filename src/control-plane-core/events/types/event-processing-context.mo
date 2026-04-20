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

import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ChannelHistoryModel "../../models/channel-history-model";
import AgentModel "../../models/agent-model";
import SlackUserModel "../../models/slack-user-model";
import WorkspaceModel "../../models/workspace-model";
import EventStoreModel "../../models/event-store-model";
import SessionModel "../../models/session-model";
import ExecutionTokenService "../../services/execution-token-service";
import ExecutionTypes "../../types/execution";

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
    /// Global agent registry — used to resolve the active agent for a given category
    agentRegistry : AgentModel.AgentRegistryState;
    /// Slack user state (cache + access change log) — handlers for membership events mutate this directly
    slackUsers : SlackUserModel.SlackUserState;
    /// Workspace channel anchors — used to resolve channel IDs to workspace scopes
    workspaces : WorkspaceModel.WorkspacesState;
    /// Event store — passed to the org-admin agent for event queue management tools
    eventStore : EventStoreModel.EventStoreState;
    /// Agent session stores (sessions, turns, traces)
    sessionStores : SessionModel.SessionStores;

    // ── Engine dispatch ────────────────────────────────────────────────

    /// Execution token store — for issuing tokens when dispatching to the engine
    executionTokenStore : ExecutionTokenService.TokenStore;

    /// Generate a unique envelope ID for engine dispatch
    generateEnvelopeId : () -> Text;

    /// Dispatch an envelope to the internal engine canister.
    /// Returns #ok on successful fire-and-forget dispatch, #err on failure.
    /// Handles engine spawning (ensureEngine) internally.
    dispatchToEngine : (ExecutionTypes.ExecutionEnvelope) -> async {
      #ok;
      #err : Text;
    };
  };
};
