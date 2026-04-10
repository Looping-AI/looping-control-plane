/// Agent Router
///
/// Sits between MessageHandler and the agent services.  Its sole
/// responsibility is: given a resolved `primaryAgent` and all the data
/// required for execution, dispatch to the correct category service.

import Time "mo:core/Time";
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

  /// Context for the work-planning agent (value streams, metrics, objectives).
  public type PlanningAgentCtx = AgentOrchestrator.PlanningAgentCtx;

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
    message : Text,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
  ) : async RouteResult {
    // Validate that the ctx variant matches the agent's declared category.
    let ctxMatchesCategory : Bool = switch (primaryAgent.category, agentCtx) {
      case (#admin, #admin(_)) { true };
      case (#planning, #planning(_)) { true };
      case (#research, #research) { true };
      case (#communication, #communication) { true };
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

    // Branch on execution type before dispatching to the category orchestrator.
    // #api agents run in-canister. #runtime agents are not yet supported.
    switch (primaryAgent.executionType) {
      case (#runtime(_)) {
        let step : Types.ProcessingStep = {
          action = "route";
          result = #err("remote runtime not yet supported");
          timestamp = Time.now();
        };
        return #err({
          message = "Agent uses a remote runtime that is not yet supported in this version.";
          steps = [step];
        });
      };
      case (#api(_)) {};
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
      message,
      workspaceKey,
      orgKey,
      turnId,
      sessionStores,
    );
  };
};
