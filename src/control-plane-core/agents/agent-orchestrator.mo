import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import KeyDerivationService "../services/key-derivation-service";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import InternalEngine "../../internal-engine/main";
import AdminAgentLoop "./categories/system/admin-agent-loop";
import OnboardingAgentLoop "./categories/system/onboarding-agent-loop";
import CustomAgentLoop "./categories/custom/custom-agent-loop";

module {
  // ─── Orchestration ───────────────────────────────────────────────────────────

  public func orchestrateAgentTalk(
    agent : AgentModel.AgentRecord,
    secrets : SecretModel.SecretsState,
    slackUserId : ?Text,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
    agentCtx : Types.AgentCtx,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
    engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
    triggerMessageText : ?Text,
    botToken : ?Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    keyCache : KeyDerivationService.KeyCache,
  ) : async Types.AgentOrchestrateResult {
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
