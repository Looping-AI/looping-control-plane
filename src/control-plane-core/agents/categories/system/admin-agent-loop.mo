import Array "mo:core/Array";
import Time "mo:core/Time";
import Error "mo:core/Error";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Json "mo:json";
import Types "../../../types";
import SecretModel "../../../models/secret-model";
import AgentModel "../../../models/agent-model";
import ExecutionTypes "../../../types/execution";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import InstructionComposer "../../instructions/instruction-composer";
import AgentHelpers "../../helpers";
import ContextAssembler "../../context-assembler";
import Constants "../../../constants";
import FunctionToolRegistry "../../tools/function-tool-registry";
import ToolExecutor "../../tools/tool-executor";
import ToolTypes "../../tools/tool-types";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import OpenRouterWrapper "../../../wrappers/openrouter-wrapper";

module {
  public func process(
    agent : AgentModel.AgentRecord,
    assembled : ContextAssembler.AssembledContext,
    _triggerMessageText : ?Text,
    turnId : Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    apiKey : Text,
    secrets : SecretModel.SecretsState,
    workspaceKey : [Nat8],
    resolveSlackBotToken : (Text -> ?Text),
    _resolveWorkspaceName : (Nat -> ?Text),
    engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
  ) : async Types.AgentOrchestrateResult {
    let instructions = InstructionComposer.compose(
      AgentHelpers.categoryToRole(agent.category, agent.config.name),
      [],
      [],
    );

    let chatMessages = messagesToChat(assembled.messages);

    let toolResources : ToolTypes.ToolResources = {
      openRouterApiKey = ?apiKey;
      workspaceId = ?agent.ownedBy;
      resolveSlackBotToken = ?(resolveSlackBotToken);
      userAuthContext;
      secrets = ?{ state = secrets; workspaceKey; write = true };
      engineDispatch = ?{
        envelopeState = engineDeps.envelopeState;
        internalEngine = engineDeps.internalEngine;
        catalogState = engineDeps.catalogState;
      };
      envelopeContext = ?{
        agent;
        turnId;
        instructions;
        messages = chatMessages;
        apiKey;
      };
    };

    let toolDefinitions = FunctionToolRegistry.getAllDefinitions(toolResources);
    let toolsOpt = if (toolDefinitions.size() == 0) null else ?toolDefinitions;

    await adminLoop(
      apiKey,
      agent.config.model,
      instructions,
      assembled.messages,
      #workspaceAgent(agent.ownedBy, agent.id),
      toolsOpt,
      toolResources,
    );
  };

  private func adminLoop(
    apiKey : Text,
    model : Text,
    instructions : Text,
    initialInput : [OpenRouterWrapper.ResponseInputMessage],
    trackId : OpenRouterWrapper.TrackId,
    toolDefinitions : ?[OpenRouterWrapper.Tool],
    toolResources : ToolTypes.ToolResources,
  ) : async Types.AgentOrchestrateResult {
    let inputHistory = List.fromArray<OpenRouterWrapper.ResponseInputMessage>(initialInput);
    var rounds : Nat = 0;

    label loop_ loop {
      if (rounds >= Constants.MAX_AGENT_ROUNDS) {
        return #err({
          message = "Core agent loop reached max rounds (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ")";
          steps = [];
        });
      };

      let response = try {
        await OpenRouterWrapper.reason(
          apiKey,
          List.toArray(inputHistory),
          model,
          trackId,
          ?instructions,
          null,
          toolDefinitions,
        );
      } catch (e : Error) {
        return #err({
          message = "Core LLM call failed: " # Error.message(e);
          steps = [];
        });
      };

      rounds += 1;

      switch (response) {
        case (#ok(#textResponse({ content; thinking = _ }))) {
          return #ok({ response = content; steps = [] });
        };
        case (#ok(#toolCalls(calls))) {
          let toolCallContent = "Using tools: " # Array.foldLeft<OpenRouterWrapper.ToolCall, Text>(
            calls,
            "",
            func(acc : Text, call : OpenRouterWrapper.ToolCall) : Text {
              if (acc == "") call.toolName else acc # ", " # call.toolName;
            },
          );
          List.add(inputHistory, { role = #assistant; content = toolCallContent });

          let toolResults = await ToolExecutor.execute(toolResources, calls);

          if (toolResultsContainDispatchSignal(toolResults)) {
            let step : Types.ProcessingStep = {
              action = "dispatch_to_engine";
              result = #ok;
              timestamp = Time.now();
            };
            return #dispatched({ steps = [step] });
          };

          let formattedResults = ToolExecutor.formatResultsForLlm(toolResults);
          List.add(inputHistory, { role = #assistant; content = formattedResults });
        };
        case (#err(msg)) {
          return #err({ message = "Core LLM error: " # msg; steps = [] });
        };
      };
    };

    #err({
      message = "Core agent loop reached max rounds (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ")";
      steps = [];
    });
  };

  private func toolResultsContainDispatchSignal(toolResults : [ToolTypes.ToolResult]) : Bool {
    for (toolResult in toolResults.vals()) {
      switch (toolResult.result) {
        case (#success(output)) {
          if (isDispatchSignal(output)) {
            return true;
          };
        };
        case (#error(_)) {};
      };
    };
    false;
  };

  private func isDispatchSignal(output : Text) : Bool {
    switch (Json.parse(output)) {
      case (#ok(json)) {
        switch (Json.get(json, "dispatched")) {
          case (?#bool(true)) { true };
          case _ { false };
        };
      };
      case _ { false };
    };
  };

  private func messagesToChat(
    msgs : [{
      role : { #user; #assistant; #system_; #developer };
      content : Text;
    }]
  ) : [ExecutionTypes.ChatMessage] {
    Array.map(
      msgs,
      func(m : { role : { #user; #assistant; #system_; #developer }; content : Text }) : ExecutionTypes.ChatMessage {
        { role = m.role; content = m.content };
      },
    );
  };
};
