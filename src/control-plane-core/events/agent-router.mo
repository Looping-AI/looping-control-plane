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
import Types "../types";
import AgentOrchestrator "../orchestrators/agent-orchestrator";
import SecretModel "../models/secret-model";
import McpToolRegistry "../tools/mcp-tool-registry";
import SessionModel "../models/session-model";

module {

  // ─── Context type aliases ─────────────────────────────────────────────────────
  //
  // Defined in AgentOrchestrator; re-exported here so callers only need one import.

  /// Context for the org-admin agent (workspace lifecycle + channel anchors).
  public type AdminAgentCtx = AgentOrchestrator.AdminAgentCtx;

  /// Per-category context union — callers construct the right variant based on
  /// `primaryAgent.category` and pass it to `route()`.
  public type AgentCtx = AgentOrchestrator.AgentCtx;

  // ─── Result type ─────────────────────────────────────────────────────────────

  /// Shared result type returned by `route()`.
  public type RouteResult = {
    #ok : { response : Text; steps : [Types.ProcessingStep] };
    #err : { message : Text; steps : [Types.ProcessingStep] };
  };

  // ─── Dispatch ────────────────────────────────────────────────────────────────

  /// Validate the `(agent.category, agentCtx)` pairing and dispatch to the
  /// orchestrator.
  ///
  /// Returns `#err` if the category tag in `agentCtx` does not match
  /// `primaryAgent.category` — this is an internal invariant violation and
  /// should never happen in production; the error message is intentionally
  /// descriptive for easier debugging.
  public func route(
    primaryAgent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
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
      case (#_system(#admin), #_system(#admin(_))) { true };
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
      mcpToolRegistry,
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
    );
  };
};
