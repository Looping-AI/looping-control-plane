import Array "mo:core/Array";
import Time "mo:core/Time";
import Error "mo:core/Error";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Json "mo:json";
import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import SessionModel "../models/session-model";
import ExecutionTypes "../types/execution";
import ExecutionTokenService "../services/execution-token-service";
import KeyDerivationService "../services/key-derivation-service";
import InstructionComposer "../instructions/instruction-composer";
import AgentHelpers "../agents/helpers";
import ContextAssembler "../agents/context-assembler";
import Constants "../constants";
import FunctionToolRegistry "../tools/function-tool-registry";
import ToolTypes "../tools/tool-types";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import LlmWrapper "../../internal-engine/wrappers/llm-wrapper";
import SlackWrapper "../wrappers/slack-wrapper";

module {

  // ─── Engine dispatch dependencies ────────────────────────────────────────────

  /// Dependencies for engine dispatch, threaded from EventProcessingContext.
  public type EngineDeps = {
    executionTokenStore : ExecutionTokenService.TokenStore;
    generateEnvelopeId : () -> Text;
    dispatchToEngine : (ExecutionTypes.ExecutionEnvelope) -> async {
      #ok;
      #err : Text;
    };
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
          triggerMessageText = null;
          workspaces = null;
          agentRegistry = null;
          secrets = ?{ state = secrets; keyCache; write = true };
          eventStore = null;
          sessionStores = null;
        };

        // Get core function tools (web_search + secrets tools via registry)
        let coreFunctionTools = FunctionToolRegistry.getAll(coreToolResources);
        let coreToolDefs = toEngineTool(coreFunctionTools);
        let allToolDefs = Array.concat(coreToolDefs, [dispatchWorkflowToolDef()]);

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
          triggerMessageText,
          botToken,
          agent,
          turnId,
          chatMessages,
          engineDeps,
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
    triggerMessageText : ?Text,
    botToken : ?Text,
    agent : AgentModel.AgentRecord,
    turnId : Text,
    envelopeMessages : [ExecutionTypes.ChatMessage],
    engineDeps : EngineDeps,
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
            if (call.toolName == "dispatch_workflow") {
              let dispatchResult = await handleDispatchWorkflow(
                call.arguments,
                triggerMessageText,
                botToken,
                apiKey,
                instructions,
                envelopeMessages,
                agent,
                turnId,
                engineDeps,
              );
              switch (dispatchResult) {
                case (#dispatched(d)) { return #dispatched(d) };
                case (#validationError(msg)) {
                  List.add(results, { callId = call.callId; output = "Permit validation failed: " # msg; success = false });
                };
              };
            } else {
              // Execute locally via FunctionToolRegistry (web_search, secrets, etc.)
              let output = await executeCoreTool(coreFunctionTools, call);
              List.add(results, { callId = call.callId; output = output.0; success = output.1 });
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

  // ─── dispatch_workflow handler ───────────────────────────────────────────────

  /// Validates permits, builds an ExecutionEnvelope, and dispatches to the engine.
  /// Returns #dispatched on success, or #validationError if a permit fails validation.
  private func handleDispatchWorkflow(
    args : Text,
    triggerMessageText : ?Text,
    botToken : ?Text,
    apiKey : Text,
    instructions : Text,
    envelopeMessages : [ExecutionTypes.ChatMessage],
    agent : AgentModel.AgentRecord,
    turnId : Text,
    engineDeps : EngineDeps,
  ) : async {
    #dispatched : { steps : [Types.ProcessingStep] };
    #validationError : Text;
  } {
    // Parse arguments
    let parsed = switch (Json.parse(args)) {
      case (#err(_)) {
        return #validationError("Invalid JSON arguments for dispatch_workflow");
      };
      case (#ok(json)) { json };
    };

    let workflowId = switch (Json.get(parsed, "workflowId")) {
      case (?#string(id)) { id };
      case (_) {
        return #validationError("Missing or invalid 'workflowId' in dispatch_workflow arguments");
      };
    };

    // Parse optional permits array
    let permits = parsePermits(parsed);

    // Validate each permit
    for (permit in permits.vals()) {
      switch (permit) {
        case (#deleteWorkspace({ workspaceId })) {
          switch (validateDeleteWorkspacePermit(triggerMessageText, workspaceId)) {
            case (#ok) {};
            case (#err(msg)) { return #validationError(msg) };
          };
        };
        case (#setAdminChannel({ channelId })) {
          switch (await validateSetAdminChannelPermit(botToken, channelId)) {
            case (#ok) {};
            case (#err(msg)) { return #validationError(msg) };
          };
        };
      };
    };

    // All permits validated — build envelope and dispatch
    let envelopeId = engineDeps.generateEnvelopeId();
    let scopeGrants = buildScopeGrants(agent);

    let tokenNonce = ExecutionTokenService.issue(
      engineDeps.executionTokenStore,
      envelopeId,
      turnId,
      agent.ownedBy,
      scopeGrants,
      permits,
    );

    let envelope : ExecutionTypes.ExecutionEnvelope = {
      envelopeId;
      envelopeVersion = 1;
      requestId = turnId;
      agentId = agent.id;
      agentName = agent.config.name;
      workspaceId = agent.ownedBy;
      workflowId;
      messages = envelopeMessages;
      instructions;
      constraints = {
        maxRounds = Constants.MAX_AGENT_ROUNDS;
        maxTokenBudget = null;
      };
      secrets = {
        apiKeys = [("openrouter", apiKey), ("model", agent.config.model)];
      };
      scopeGrants;
      permits;
      tokenNonce;
    };

    try {
      switch (await engineDeps.dispatchToEngine(envelope)) {
        case (#ok) {
          let step : Types.ProcessingStep = {
            action = "dispatch_to_engine";
            result = #ok;
            timestamp = Time.now();
          };
          #dispatched({ steps = [step] });
        };
        case (#err(e)) {
          ExecutionTokenService.revoke(engineDeps.executionTokenStore, tokenNonce);
          #validationError("Engine dispatch failed: " # e);
        };
      };
    } catch (e : Error) {
      ExecutionTokenService.revoke(engineDeps.executionTokenStore, tokenNonce);
      #validationError("Engine call failed: " # Error.message(e));
    };
  };

  // ─── Permit validation ───────────────────────────────────────────────────────

  /// Validate #deleteWorkspace permit: the user's trigger message must contain
  /// "delete" as confirmation. This prevents the LLM from fabricating a delete
  /// confirmation that the user never typed.
  private func validateDeleteWorkspacePermit(
    triggerMessageText : ?Text,
    _workspaceId : Nat,
  ) : { #ok; #err : Text } {
    switch (triggerMessageText) {
      case (null) {
        #err("Cannot validate delete workspace permit: no trigger message available");
      };
      case (?text) {
        let lower = Text.toLower(text);
        if (Text.contains(lower, #text "delete")) {
          #ok;
        } else {
          #err("User's message does not contain 'delete' confirmation. Ask the user to explicitly confirm deletion in their message.");
        };
      };
    };
  };

  /// Validate #setAdminChannel permit: verify the channel exists and is
  /// accessible via the Slack API.
  private func validateSetAdminChannelPermit(
    botToken : ?Text,
    channelId : Text,
  ) : async { #ok; #err : Text } {
    switch (botToken) {
      case (null) {
        #err("Cannot validate admin channel permit: no Slack bot token available");
      };
      case (?token) {
        try {
          switch (await SlackWrapper.getChannelInfo(token, channelId)) {
            case (#ok(_)) { #ok };
            case (#err(e)) {
              #err("Channel verification failed for " # channelId # ": " # e);
            };
          };
        } catch (e : Error) {
          #err("Slack API call failed: " # Error.message(e));
        };
      };
    };
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

  /// dispatch_workflow tool definition for the Core LLM loop.
  private func dispatchWorkflowToolDef() : LlmWrapper.Tool {
    {
      tool_type = "function";
      function_ = {
        name = "dispatch_workflow";
        description = ?"Dispatches a workflow to the execution engine for administrative operations. Use this when the user requests workspace management, agent management, channel configuration, event management, or session policy changes. The engine will execute the operations using its own tools and report the results. For most operations, pass an empty permits array. Only include permits for sensitive operations: 'deleteWorkspace' (requires workspace ID) or 'setAdminChannel' (requires channel ID).";
        parameters = ?"{\"type\":\"object\",\"properties\":{\"workflowId\":{\"type\":\"string\",\"description\":\"The workflow ID to execute. Use 'admin-v1' for administrative operations.\"},\"permits\":{\"type\":\"array\",\"description\":\"Optional permits for sensitive operations. Empty array for standard operations.\",\"items\":{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"deleteWorkspace\",\"setAdminChannel\"],\"description\":\"The permit type.\"},\"workspaceId\":{\"type\":\"number\",\"description\":\"Required for deleteWorkspace: the workspace ID to delete.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Required for setAdminChannel: the Slack channel ID to set as admin channel.\"}},\"required\":[\"type\"]}}},\"required\":[\"workflowId\"]}";
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

  /// Parse a JSON permits array into [OperationPermit].
  private func parsePermits(json : Json.Json) : [ExecutionTypes.OperationPermit] {
    let permitsJson = switch (Json.get(json, "permits")) {
      case (?#array(arr)) { arr };
      case (_) { return [] };
    };
    let result = List.empty<ExecutionTypes.OperationPermit>();
    for (p in permitsJson.vals()) {
      let permitType = switch (Json.get(p, "type")) {
        case (?#string(t)) { t };
        case (_) { "" };
      };
      if (permitType == "deleteWorkspace") {
        switch (Json.get(p, "workspaceId")) {
          case (?#number(#int(n))) {
            List.add(result, #deleteWorkspace({ workspaceId = Int.abs(n) }));
          };
          case (?#number(#float(f))) {
            List.add(result, #deleteWorkspace({ workspaceId = Int.abs(Float.toInt(f)) }));
          };
          case (_) {};
        };
      } else if (permitType == "setAdminChannel") {
        switch (Json.get(p, "channelId")) {
          case (?#string(c)) {
            List.add(result, #setAdminChannel({ channelId = c }));
          };
          case (_) {};
        };
      };
    };
    List.toArray(result);
  };

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  /// Build scope grants based on agent category and ownership.
  private func buildScopeGrants(agent : AgentModel.AgentRecord) : [ExecutionTypes.ScopeGrant] {
    switch (agent.category) {
      case (#_system(#admin)) {
        if (AgentModel.isOrgAdmin(agent)) {
          [
            #workspace({ access = #write }),
            #agents({ access = #write }),
            #slackQueue({ access = #write }),
            #session({ access = #write }),
          ];
        } else {
          [
            #workspace({ access = #read }),
            #agents({ access = #write }),
            #session({ access = #write }),
          ];
        };
      };
      case (#_system(#onboarding) or #custom) {
        [#agent({ id = agent.id; access = #read })];
      };
    };
  };

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
