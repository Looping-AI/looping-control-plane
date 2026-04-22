import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import KeyDerivationService "../services/key-derivation-service";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import InternalEngine "../../internal-engine/main";
import AdminAgentLoop "../agents/system/admin-agent-loop";
import OnboardingAgentLoop "../agents/system/onboarding-agent-loop";
import CustomAgentLoop "../agents/custom/custom-agent-loop";

module {

  // ─── Engine dispatch dependencies ────────────────────────────────────────────

  /// Dependencies for engine dispatch, threaded from EventProcessingContext.
  public type EngineDeps = {
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    internalEngine : InternalEngine.InternalEngine;
  };

  // ─── Context types ───────────────────────────────────────────────────────────

  /// Typed per-category context union — mirrors AgentCategory nesting.
  /// The variant tag gates dispatch; no payload is needed since the orchestrator
  /// reads all state from EventProcessingContext / params.
  public type AgentCtx = {
    #_system : { #admin; #onboarding };
    #custom;
  };

  // ─── Result type ─────────────────────────────────────────────────────────────

  /// Result from orchestrateAgentTalk.
  /// - #dispatched: envelope accepted by engine (response comes async via events)
  /// - #ok: synchronous response (future: non-engine agents)
  /// - #err: immediate failure
  public type OrchestrateResult = {
    #dispatched : { steps : [Types.ProcessingStep] };
    #ok : {
      response : Text;
      steps : [Types.ProcessingStep];
    };
    #err : {
      message : Text;
      steps : [Types.ProcessingStep];
    };
  };

  // ─── Orchestration ───────────────────────────────────────────────────────────

  public func orchestrateAgentTalk(
    agent : AgentModel.AgentRecord,
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
    engineDeps : EngineDeps,
    triggerMessageText : ?Text,
    botToken : ?Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    keyCache : KeyDerivationService.KeyCache,
  ) : async OrchestrateResult {
    switch (agentCtx) {
      case (#_system(#admin)) {
        await AdminAgentLoop.process(
          agent,
          secrets,
          slackUserId,
          channelHistory,
          channelId,
          threadTs,
          workspaceKey,
          orgKey,
          turnId,
          sessionStores,
          engineDeps,
          triggerMessageText,
          botToken,
          userAuthContext,
          keyCache,
        );
      };
      case (#_system(#onboarding)) {
        await OnboardingAgentLoop.process(
          agent,
          secrets,
          slackUserId,
          channelHistory,
          channelId,
          threadTs,
          workspaceKey,
          orgKey,
          turnId,
          sessionStores,
          engineDeps,
          triggerMessageText,
          botToken,
          userAuthContext,
          keyCache,
        );
      };
      case (#custom) {
        await CustomAgentLoop.process(
          agent,
          secrets,
          slackUserId,
          channelHistory,
          channelId,
          threadTs,
          workspaceKey,
          orgKey,
          turnId,
          sessionStores,
          engineDeps,
          triggerMessageText,
          botToken,
          userAuthContext,
          keyCache,
        );
      };
    };
  };
};
