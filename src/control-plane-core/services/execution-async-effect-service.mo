import Nat "mo:core/Nat";
import Types "../types";
import SessionModel "../models/session-model";
import AgentModel "../models/agent-model";
import WorkspaceModel "../models/workspace-model";
import SecretModel "../models/secret-model";
import KeyDerivationService "key-derivation-service";
import ExecutionTypes "../types/execution";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";

module {

  // ── Dependencies (captured at construction time — all stable let-bindings) ──

  public type ServiceDeps = {
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    workspaces : WorkspaceModel.WorkspacesState;
    secrets : SecretModel.SecretsState;
  };

  public class Service(deps : ServiceDeps) {

    /// Process a single execution async effect — posts results to Slack and completes turns.
    /// `keyCache` is passed at call time (not captured in deps) because it is a transient
    /// var in main.mo that may be replaced by the 30-day key-rotation timer; capturing it
    /// at construction would leave the service with a stale reference after rotation.
    public func processEffect(
      keyCache : KeyDerivationService.KeyCache,
      effect : ExecutionTypes.AsyncEffect,
    ) : async () {
      let (envelopeId, turnId, humanSummary) = switch (effect) {
        case (#milestone(m)) { (m.envelopeId, m.turnId, m.humanSummary) };
        case (#complete(c)) { (c.envelopeId, c.turnId, c.humanSummary) };
      };

      // Look up the turn to get source context
      let turn = switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
        case (?t) { t };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Turn not found: " # turnId # " (envelope=" # Nat.toText(envelopeId) # ")");
          return;
        };
      };

      // Look up agent for metadata and workspace context
      let agent = switch (AgentModel.lookupById(deps.agentRegistry, turn.agentId)) {
        case (?a) { a };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Agent not found: " # Nat.toText(turn.agentId));
          return;
        };
      };

      // For non-Slack sources (timer, GitHub, etc.), fall back to the agent's workspace
      // admin channel so execution is observable rather than silently lost.
      // ts and threadTs are null since there is no parent message to thread under.
      let (channelId, ts, threadTs) = switch (turn.sourceRef) {
        case (?#slack(s)) { (s.channelId, s.ts, s.threadTs) };
        case (_) {
          let adminChannel = switch (WorkspaceModel.getWorkspace(deps.workspaces, agent.ownedBy)) {
            case (?ws) { ws.adminChannelId };
            case null { null };
          };
          switch (adminChannel) {
            case (?ch) { (ch, "", null) };
            case null {
              Logger.log(#error, ?"ExecutionAsyncEffect", "No admin channel for non-Slack turn " # turnId # " — cannot post result");
              return;
            };
          };
        };
      };

      // Derive bot token
      let orgKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
      let botToken = switch (
        SecretModel.resolvePlatformSecret(
          deps.secrets,
          orgKey,
          null,
          #slackBotToken,
          {
            slackUserId = null;
            agentId = null;
            operation = "async-effect:bot-token";
          },
        )
      ) {
        case (?t) { t };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Bot token not available for turn " # turnId);
          return;
        };
      };

      // Build metadata matching the message-handler pattern
      let metadata : ?Types.AgentMessageMetadata = ?{
        event_type = "looping_agent_message";
        event_payload = {
          parent_agent = agent.config.name;
          parent_ts = ts;
          parent_channel = channelId;
          turn_id = turnId;
        };
      };

      switch (effect) {
        case (#milestone(_m)) {
          // Post milestone update to Slack thread
          switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata)) {
            case (#ok(_)) {};
            case (#err(e)) {
              Logger.log(#error, ?"ExecutionAsyncEffect", "Milestone post failed for turn " # turnId # ": " # e);
            };
          };
        };
        case (#complete(c)) {
          // Post final response
          switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata)) {
            case (#ok({ ts = replyTs; channel = _ })) {
              SessionModel.appendTrace(
                deps.sessionStores,
                turnId,
                #slackPost({
                  channelId;
                  threadTs;
                  ts = replyTs;
                }),
              );
            };
            case (#err(e)) {
              Logger.log(#error, ?"ExecutionAsyncEffect", "Reply post failed for turn " # turnId # ": " # e);
            };
          };

          // Map engine execution status to turn status and cost
          let (turnStatus, errorSummary) = switch (c.status) {
            case (#completed) { (#succeeded, null) };
            case (#failed(reason)) { (#failed, ?reason) };
            case (#roundLimitReached) { (#failed, ?"Round limit reached") };
          };

          let turnCost : ?SessionModel.TurnCost = ?{
            promptTokens = c.stats.inputTokens;
            completionTokens = c.stats.outputTokens;
            estimatedDollarCost = c.stats.estimatedDollarCost;
          };

          SessionModel.completeTurn(deps.sessionStores, turnId, turnStatus, turnCost, errorSummary);
        };
      };
    };
  };
};
