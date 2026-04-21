import Array "mo:core/Array";
import Time "mo:core/Time";
import Error "mo:core/Error";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Json "mo:json";
import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionTypes "../types/execution";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import KeyDerivationService "../services/key-derivation-service";
import InstructionComposer "../instructions/instruction-composer";
import AgentHelpers "../agents/helpers";
import ContextAssembler "../agents/context-assembler";
import Constants "../constants";
import FunctionToolRegistry "../tools/function-tool-registry";
import ToolTypes "../tools/tool-types";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import LlmWrapper "../../internal-engine/wrappers/llm-wrapper";
import InternalEngine "../../internal-engine/main";

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
    // Stub categories return early before touching secrets
    switch (agentCtx) {
      case (#_system(#onboarding)) {
        let step : Types.ProcessingStep = {
          action = "orchestrate";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        return #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
      case (#custom) {
        let step : Types.ProcessingStep = {
          action = "orchestrate";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        return #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
      case _ {};
    };

    // Resolve the LLM API key with 3-level cascade
    let apiKey = SecretModel.resolveSecret(secrets, agent, agent.ownedBy, #openRouterApiKey, workspaceKey, orgKey, { slackUserId; agentId = ?agent.id; operation = "agent-orchestrator" });

    switch (apiKey) {
      case (null) {
        #err({
          message = "No OpenRouter API key found for agent talk. Please store the API key first.";
          steps = [];
        });
      };
      case (?key) {
        // ── Core LLM loop for admin agents ─────────────────────────────

        // Build instructions from agent configuration
        let instructions = InstructionComposer.compose(
          AgentHelpers.categoryToRole(agent.category, agent.config.name),
          [],
          [],
        );

        // Assemble LLM context messages from session + channel + thread history
        let assembled = ContextAssembler.assemble(
          sessionStores,
          agent.id,
          turnId,
          channelHistory,
          channelId,
          threadTs,
        );

        let chatMessages = messagesToChat(assembled.messages);

        // Build ToolResources with secrets support
        let coreToolResources : ToolTypes.ToolResources = {
          openRouterApiKey = ?key;
          workspaceId = ?agent.ownedBy;
          resolveSlackBotToken = null;
          userAuthContext;
          triggerMessageText;
          workspaces = null;
          agentRegistry = null;
          secrets = ?{ state = secrets; keyCache; write = true };
          eventStore = null;
          sessionStores = null;
          engineDispatch = ?{
            envelopeState = engineDeps.envelopeState;
            internalEngine = engineDeps.internalEngine;
          };
          envelopeContext = ?{
            agent;
            turnId;
            instructions;
            messages = chatMessages;
            botToken;
            apiKey = key;
          };
        };

        // Get all function tools (includes dispatch_workflow via registry)
        let coreFunctionTools = FunctionToolRegistry.getAll(coreToolResources);
        let allToolDefs = toEngineTool(coreFunctionTools);

        // Convert assembled messages to LlmWrapper InputItem format
        let inputItems = Array.map<ExecutionTypes.ChatMessage, LlmWrapper.InputItem>(
          chatMessages,
          func(m : ExecutionTypes.ChatMessage) : LlmWrapper.InputItem {
            #message(m);
          },
        );

        // Run the Core LLM loop
        await coreAdminLoop(
          key,
          agent.config.model,
          instructions,
          inputItems,
          allToolDefs,
          coreFunctionTools,
        );
      };
    };
  };

  // ─── Core LLM Loop ──────────────────────────────────────────────────────────

  /// Multi-round LLM loop for admin agents. The Core reasons with web_search
  /// and dispatch_workflow. Text responses are returned synchronously (#ok).
  /// dispatch_workflow validates permits, builds an envelope, and dispatches
  /// to the engine (#dispatched).
  private func coreAdminLoop(
    apiKey : Text,
    model : Text,
    instructions : Text,
    initialInput : [LlmWrapper.InputItem],
    toolDefs : [LlmWrapper.Tool],
    coreFunctionTools : [FunctionToolRegistry.FunctionTool],
  ) : async OrchestrateResult {
    let inputHistory = List.empty<LlmWrapper.InputItem>();
    for (item in initialInput.vals()) {
      List.add(inputHistory, item);
    };

    var rounds : Nat = 0;

    label loop_ loop {
      if (rounds >= Constants.MAX_AGENT_ROUNDS) {
        return #err({
          message = "Core agent loop reached max rounds (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ")";
          steps = [];
        });
      };

      let response = try {
        await LlmWrapper.reason(
          apiKey,
          List.toArray(inputHistory),
          model,
          ?instructions,
          null,
          ?toolDefs,
        );
      } catch (e : Error) {
        return #err({
          message = "Core LLM call failed: " # Error.message(e);
          steps = [];
        });
      };

      rounds += 1;

      switch (response.result) {
        // ── Text response — return synchronously ──
        case (#ok(#textResponse({ content; thinking = _ }))) {
          return #ok({ response = content; steps = [] });
        };

        // ── Tool calls — execute and loop ──
        case (#ok(#toolCalls(calls))) {
          let results = List.empty<{ callId : Text; output : Text; success : Bool }>();

          for (call in calls.vals()) {
            let output = await executeCoreTool(coreFunctionTools, call);
            List.add(results, { callId = call.callId; output = output.0; success = output.1 });
          };

          // Check for dispatch signal — dispatch_workflow returns {"dispatched":true} on success.
          // Detect it here so the orchestrator can return #dispatched without a special case in
          // the tool-call branch. Errors from dispatch_workflow ({"dispatched":false}) flow back
          // to the LLM normally so it can reason about the failure.
          for (result in List.toArray(results).vals()) {
            switch (Json.parse(result.output)) {
              case (#ok(json)) {
                switch (Json.get(json, "dispatched")) {
                  case (?#bool(true)) {
                    let step : Types.ProcessingStep = {
                      action = "dispatch_to_engine";
                      result = #ok;
                      timestamp = Time.now();
                    };
                    return #dispatched({ steps = [step] });
                  };
                  case _ {};
                };
              };
              case _ {};
            };
          };

          // Feed results back to LLM
          let roundInput = LlmWrapper.toolRoundToInput(calls, List.toArray(results));
          for (item in roundInput.vals()) {
            List.add(inputHistory, item);
          };
        };

        // ── LLM error ──
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

  // ─── Tool helpers ────────────────────────────────────────────────────────────

  /// Execute a core function tool by name lookup.
  private func executeCoreTool(
    tools : [FunctionToolRegistry.FunctionTool],
    call : LlmWrapper.ToolCall,
  ) : async (Text, Bool) {
    let found = Array.find<FunctionToolRegistry.FunctionTool>(
      tools,
      func(t : FunctionToolRegistry.FunctionTool) : Bool {
        t.definition.function.name == call.toolName;
      },
    );
    switch (found) {
      case (?tool) {
        try {
          let result = await tool.handler(call.arguments);
          (result, true);
        } catch (e : Error) {
          ("Tool execution error: " # Error.message(e), false);
        };
      };
      case (null) {
        ("Unknown tool: " # call.toolName, false);
      };
    };
  };

  /// Convert Core FunctionTool definitions to engine LlmWrapper.Tool format.
  /// The only difference is the field name: Core uses `function`, engine uses `function_`.
  private func toEngineTool(
    tools : [FunctionToolRegistry.FunctionTool]
  ) : [LlmWrapper.Tool] {
    Array.map<FunctionToolRegistry.FunctionTool, LlmWrapper.Tool>(
      tools,
      func(t : FunctionToolRegistry.FunctionTool) : LlmWrapper.Tool {
        {
          tool_type = t.definition.tool_type;
          function_ = {
            name = t.definition.function.name;
            description = t.definition.function.description;
            parameters = t.definition.function.parameters;
          };
        };
      },
    );
  };

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  /// Convert OpenRouter ResponseInputMessages to ExecutionTypes ChatMessages.
  /// Both types are structurally identical ({role; content}) so this is a
  /// straightforward projection.
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
