import Time "mo:core/Time";
import Types "../../../types";
import AgentModel "../../../models/agent-model";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import ContextAssembler "../../context-assembler";

module {
  public func process(
    _agent : AgentModel.AgentRecord,
    _assembled : ContextAssembler.AssembledContext,
    _triggerMessageText : ?Text,
    _turnId : Text,
    _userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    _apiKey : Text,
    _resolveSlackBotToken : (Text -> ?Text),
    _engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
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
