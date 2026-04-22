import Time "mo:core/Time";
import Types "../../../types";
import SecretModel "../../../models/secret-model";
import AgentModel "../../../models/agent-model";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import KeyDerivationService "../../../services/key-derivation-service";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import ContextAssembler "../../context-assembler";

module {
  public func process(
    _agent : AgentModel.AgentRecord,
    _secrets : SecretModel.SecretsState,
    _apiKey : Text,
    _assembled : ContextAssembler.AssembledContext,
    _turnId : Text,
    _engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
    _triggerMessageText : ?Text,
    _resolveSlackBotToken : (Text -> ?Text),
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
