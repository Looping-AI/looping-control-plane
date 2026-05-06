import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Error "mo:core/Error";
import Types "../types";
import SessionModel "../models/session-model";
import AgentModel "../models/agent-model";
import WorkspaceModel "../models/workspace-model";
import SecretModel "../models/secret-model";
import ApprovalModel "../models/approval-model";
import KeyDerivationService "key-derivation-service";
import WorkflowTypes "../types/workflow";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";
import AgentHelpers "../agents/helpers";
import TurnCompletionService "turn-completion-service";
import TurnSuspensionService "turn-suspension-service";

module {

  // ── Dependencies (captured at construction time — all stable let-bindings) ──

  public type ServiceDeps = {
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    workspaces : WorkspaceModel.WorkspacesState;
    secrets : SecretModel.SecretsState;
    approvalState : ApprovalModel.ApprovalState;
    resumeAdminTurn : (turnId : Text, suspension : SessionModel.SuspensionData, syntheticToolResult : Text) -> async Types.AgentOrchestrateResult;
  };

  public class Service(deps : ServiceDeps) {

    /// Process a single workflow async effect — posts results to Slack and completes turns.
    /// `keyCache` is passed at call time (not captured in deps) because it is a transient
    /// var in main.mo that may be replaced by the 30-day key-rotation timer; capturing it
    /// at construction would leave the service with a stale reference after rotation.
    public func processEffect(
      keyCache : KeyDerivationService.KeyCache,
      effect : WorkflowTypes.AsyncEffect,
    ) : async () {
      let (envelopeId, turnId, humanSummary) = switch (effect) {
        case (#milestone(m)) { (m.envelopeId, m.turnId, m.humanSummary) };
        case (#complete(c)) { (c.envelopeId, c.turnId, c.humanSummary) };
      };

      // Look up the turn to get source context
      let turn = switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
        case (?t) { t };
        case null {
          Logger.log(#error, ?"WorkflowAsyncEffect", "Turn not found: " # turnId # " (envelope=" # Nat.toText(envelopeId) # ")");
          return;
        };
      };

      // Look up agent for metadata and workspace context
      let agent = switch (AgentModel.lookupById(deps.agentRegistry, turn.agentId)) {
        case (?a) { a };
        case null {
          Logger.log(#error, ?"WorkflowAsyncEffect", "Agent not found: " # Nat.toText(turn.agentId));
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
              Logger.log(#error, ?"WorkflowAsyncEffect", "No admin channel for non-Slack turn " # turnId # " — cannot post result");
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
          Logger.log(#error, ?"WorkflowAsyncEffect", "Bot token not available for turn " # turnId);
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
          switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata, null)) {
            case (#ok(_)) {};
            case (#err(e)) {
              Logger.log(#error, ?"WorkflowAsyncEffect", "Milestone post failed for turn " # turnId # ": " # e);
            };
          };
        };
        case (#complete(c)) {
          // One-shot guard: atomically check #awaitingWorkflow and flip to #running.
          // Returns #err if the turn is not in #awaitingWorkflow (e.g. duplicate event),
          // in which case we fall through to normal terminal-completion handling.
          let suspension = switch (SessionModel.resumeFromWorkflow(deps.sessionStores, turnId)) {
            case (#ok(s)) { s };
            case (#err(_)) {
              // Not awaiting a workflow result — treat as a normal completion.
              switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata, null)) {
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
                  Logger.log(#error, ?"WorkflowAsyncEffect", "Reply post failed for turn " # turnId # ": " # e);
                };
              };

              let (turnStatus, errorSummary) = switch (c.status) {
                case (#completed) { (#succeeded, null) };
                case (#failed(reason)) { (#failed, ?reason) };
                case (#roundLimitReached) { (#failed, ?"Round limit reached") };
              };

              let turnCost : ?SessionModel.TurnCost = switch (c.stats.inputTokens, c.stats.outputTokens) {
                case (?inp, ?out) {
                  ?{
                    promptTokens = inp;
                    completionTokens = out;
                    estimatedDollarCost = c.stats.estimatedDollarCost;
                  };
                };
                case (_) { null };
              };

              SessionModel.completeTurn(deps.sessionStores, turnId, turnStatus, turnCost, errorSummary);
              return;
            };
          };

          // Resume: inject the engine result as a synthetic tool result and continue the LLM loop.
          let syntheticResult = AgentHelpers.buildSyntheticToolResult(c);
          let resumeResult = try {
            await deps.resumeAdminTurn(turnId, suspension, syntheticResult);
          } catch (e) {
            Logger.log(#error, ?"WorkflowAsyncEffect", "resumeAdminTurn threw for turn " # turnId # ": " # Error.message(e));
            let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
            SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?"Resume call failed");
            return;
          };
          switch (resumeResult) {
            case (#ok(_) or #err(_)) {
              ignore await TurnCompletionService.complete(
                { sessionStores = deps.sessionStores },
                turnId,
                resumeResult,
                { botToken; channelId; threadTs; metadata },
              );
            };
            case (#dispatched(_) or #awaitingApproval(_)) {
              ignore TurnSuspensionService.suspend(
                {
                  sessionStores = deps.sessionStores;
                  approvalState = deps.approvalState;
                },
                turnId,
                resumeResult,
              );
            };
          };
        };
      };
    };
  };
};
