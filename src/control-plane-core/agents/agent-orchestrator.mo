import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import KeyDerivationService "../services/key-derivation-service";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import ContextAssembler "./context-assembler";
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
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    keyCache : KeyDerivationService.KeyCache,
  ) : async Types.AgentOrchestrateResult {
    let apiKey = switch (SecretModel.resolveSecret(secrets, agent, agent.ownedBy, #openRouterApiKey, workspaceKey, orgKey, { slackUserId; agentId = ?agent.id; operation = "agent-orchestrator" })) {
      case (null) {
        return #err({
          message = "No OpenRouter API key found for agent talk. Please store the API key first.";
          steps = [];
        });
      };
      case (?key) { key };
    };

    let assembled = ContextAssembler.assemble(
      sessionStores,
      agent.id,
      turnId,
      channelHistory,
      channelId,
      threadTs,
    );

    let resolveSlackBotToken : (Text -> ?Text) = func(operation : Text) : ?Text {
      SecretModel.resolvePlatformSecret(
        secrets,
        orgKey,
        null,
        #slackBotToken,
        { slackUserId = null; agentId = null; operation },
      );
    };

    switch (agentCtx) {
      case (#_system(#admin)) {
        await AdminAgentLoop.process(
          agent,
          secrets,
          apiKey,
          assembled,
          turnId,
          engineDeps,
          triggerMessageText,
          resolveSlackBotToken,
          userAuthContext,
          keyCache,
        );
      };
      case (#_system(#onboarding)) {
        await OnboardingAgentLoop.process(
          agent,
          secrets,
          apiKey,
          assembled,
          turnId,
          engineDeps,
          triggerMessageText,
          resolveSlackBotToken,
          userAuthContext,
          keyCache,
        );
      };
      case (#custom) {
        await CustomAgentLoop.process(
          agent,
          secrets,
          apiKey,
          assembled,
          turnId,
          engineDeps,
          triggerMessageText,
          resolveSlackBotToken,
          userAuthContext,
          keyCache,
        );
      };
    };
  };
};
