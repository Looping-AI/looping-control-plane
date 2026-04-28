import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import ContextAssembler "./context-assembler";
import AdminAgentLoop "./categories/system/admin-agent-loop";
import OnboardingAgentLoop "./categories/system/onboarding-agent-loop";
import CustomAgentLoop "./categories/custom/custom-agent-loop";

module {
  // ─── Orchestration ───────────────────────────────────────────────────

  public func orchestrate(
    agent : AgentModel.AgentRecord,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
    triggerMessageText : ?Text,
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    slackUserId : ?Text,
    secrets : SecretModel.SecretsState,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
  ) : async Types.AgentOrchestrateResult {

    // ── API key ──────────────────────────────────────────────────────────────
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

    // ── Dispatch to category loop ────────────────────────────────────────────
    switch (agent.category) {
      case (#_system(#admin)) {
        await AdminAgentLoop.process(
          agent,
          assembled,
          turnId,
          userAuthContext,
          apiKey,
          secrets,
          workspaceKey,
          resolveSlackBotToken,
          engineDeps,
        );
      };
      case (#_system(#onboarding)) {
        await OnboardingAgentLoop.process(
          agent,
          assembled,
          triggerMessageText,
          turnId,
          userAuthContext,
          apiKey,
          resolveSlackBotToken,
          engineDeps,
        );
      };
      case (#custom) {
        await CustomAgentLoop.process(
          agent,
          assembled,
          triggerMessageText,
          turnId,
          userAuthContext,
          apiKey,
          resolveSlackBotToken,
          engineDeps,
        );
      };
    };
  };
};
