import Time "mo:core/Time";
import Types "../../../types";
import SecretModel "../../../models/secret-model";
import ChannelHistoryModel "../../../models/channel-history-model";
import AgentModel "../../../models/agent-model";
import SessionModel "../../../models/session-model";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import KeyDerivationService "../../../services/key-derivation-service";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";

module {
  public func process(
    _agent : AgentModel.AgentRecord,
    _secrets : SecretModel.SecretsState,
    _slackUserId : ?Text,
    _channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    _channelId : Text,
    _threadTs : ?Text,
    _workspaceKey : [Nat8],
    _orgKey : [Nat8],
    _turnId : Text,
    _sessionStores : SessionModel.SessionStores,
    _engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
    _triggerMessageText : ?Text,
    _botToken : ?Text,
    _userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    _keyCache : KeyDerivationService.KeyCache,
  ) : async Types.AgentOrchestrateResult {
    let step : Types.ProcessingStep = {
      action = "orchestrate";
      result = #err("category service not yet implemented");
      timestamp = Time.now();
    };
    #err({
      message = "category service not yet implemented";
      steps = [step];
    });
  };
};
