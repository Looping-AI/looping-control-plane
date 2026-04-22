/// Agent Router
///
/// Sits between MessageHandler and the agent services.  Its sole
/// responsibility is: given a resolved `primaryAgent` and all the data
/// required for execution, dispatch to the correct category service.

import Time "mo:core/Time";
import Set "mo:core/Set";
import Text "mo:core/Text";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import Types "../types";
import AgentOrchestrator "../agents/agent-orchestrator";
import SecretModel "../models/secret-model";
import SessionModel "../models/session-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import KeyDerivationService "../services/key-derivation-service";

module {

  // ─── Context type aliases ─────────────────────────────────────────────────────

  /// Per-category context union — callers construct the right variant based on
  /// `primaryAgent.category` and pass it to `route()`.
  public type AgentCtx = Types.AgentCtx;

  /// Engine dispatch dependencies — threaded from EventProcessingContext.
  public type EngineDeps = Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>;

  // ─── Result type ─────────────────────────────────────────────────────────────

  /// Shared result type returned by `route()`.
  public type RouteResult = Types.AgentOrchestrateResult;

  // ─── Dispatch ────────────────────────────────────────────────────────────────

  public func route(
    primaryAgent : AgentModel.AgentRecord,
    secrets : SecretModel.SecretsState,
    slackUserId : ?Text,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
    agentCtx : AgentCtx,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
    agentAdminChannelId : ?Text,
    engineDeps : EngineDeps,
    triggerMessageText : ?Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    keyCache : KeyDerivationService.KeyCache,
  ) : async RouteResult {
    // Channel guard — split by category:
    // - #admin agents: routing is governed by the agent's workspace's adminChannelId
    //   (single source of truth in WorkspaceModel). null means not yet configured
    //   — block unconditionally; there is no bootstrap bypass.
    // - All other categories: enforce the agent's static allowedChannelIds set.
    switch (primaryAgent.category) {
      case (#_system(#admin)) {
        let allowedId = switch (agentAdminChannelId) {
          case (null) {
            let step : Types.ProcessingStep = {
              action = "route";
              result = #err("admin channel not yet configured");
              timestamp = Time.now();
            };
            return #err({
              message = "The admin channel for this workspace has not yet been configured. Use set_workspace_admin_channel to anchor it.";
              steps = [step];
            });
          };
          case (?id) { id };
        };
        if (allowedId != channelId) {
          let step : Types.ProcessingStep = {
            action = "route";
            result = #err("channel not admin channel");
            timestamp = Time.now();
          };
          return #err({
            message = "Agent '" # primaryAgent.config.name # "' can only be invoked from the configured admin channel (" # allowedId # ").";
            steps = [step];
          });
        };
      };
      case (_) {
        if (not Set.contains(primaryAgent.config.allowedChannelIds, Text.compare, channelId)) {
          let allowedList = Text.join(Set.values(primaryAgent.config.allowedChannelIds), ", ");
          let step : Types.ProcessingStep = {
            action = "route";
            result = #err("channel not in allowlist");
            timestamp = Time.now();
          };
          return #err({
            message = "Agent '" # primaryAgent.config.name # "' is not configured for channel " # channelId # ". Allowed channels: " # allowedList # ".";
            steps = [step];
          });
        };
      };
    };

    // Validate that the ctx variant matches the agent's declared category.
    let ctxMatchesCategory : Bool = switch (primaryAgent.category, agentCtx) {
      case (#_system(#admin), #_system(#admin)) { true };
      case (#_system(#onboarding), #_system(#onboarding)) { true };
      case (#custom, #custom) { true };
      case _ { false };
    };

    if (not ctxMatchesCategory) {
      let step : Types.ProcessingStep = {
        action = "route";
        result = #err("agent context mismatch");
        timestamp = Time.now();
      };
      return #err({
        message = "agent context mismatch: category=" # debug_show (primaryAgent.category) # " does not match the provided agentCtx variant";
        steps = [step];
      });
    };

    // Forward to the orchestrator with the typed context
    await AgentOrchestrator.orchestrateAgentTalk(
      primaryAgent,
      secrets,
      slackUserId,
      channelHistory,
      channelId,
      threadTs,
      agentCtx,
      workspaceKey,
      orgKey,
      turnId,
      sessionStores,
      engineDeps,
      triggerMessageText,
      userAuthContext,
      keyCache,
    );
  };
};
