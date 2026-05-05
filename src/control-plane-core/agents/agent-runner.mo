/// AgentRunner
///
/// Single entry point for both new-turn orchestration (`start`) and
/// engine-completion resume (`resume`). Consolidates the per-category dispatch
/// and the large `resumeAdminTurn` closure that previously lived in `main.mo`.
///
/// `start`  — category-dispatching fresh-turn path; called directly from
///             `message-handler` and `test-canister`.
///
/// `resume` — injected-result resume path; `main.mo`'s `resumeAdminTurn` closure
///             delegates here.

import Array "mo:core/Array";
import Json "mo:json";
import Error "mo:core/Error";
import Time "mo:core/Time";
import Types "../types";
import AgentModel "../models/agent-model";
import ChannelHistoryModel "../models/channel-history-model";
import SecretModel "../models/secret-model";
import SessionModel "../models/session-model";
import ApprovalModel "../models/approval-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import ExecutionTypes "../types/execution";
import WorkflowCatalogModel "../models/workflow-catalog-model";
import WorkflowCatalogTypes "../types/workflow-catalog";
import TurnContextService "../services/turn-context-service";
import TurnSuspensionService "../services/turn-suspension-service";
import TurnCompletionService "../services/turn-completion-service";
import KeyDerivationService "../services/key-derivation-service";
import WorkflowCatalogService "../services/workflow-catalog-service";
import ContextAssembler "context-assembler";
import AdminAgentLoop "categories/system/admin-agent-loop";
import OnboardingAgentLoop "categories/system/onboarding-agent-loop";
import CustomAgentLoop "categories/custom/custom-agent-loop";
import AgentHelpers "helpers";
import InstructionComposer "instructions/instruction-composer";
import ToolTypes "tools/tool-types";
import WorkflowEngineHandler "tools/handlers/workflow-engine-handler";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";
import InternalEngine "../../internal-engine/main";

module {
  // ── Types ──────────────────────────────────────────────────────────────────

  /// Dependencies threaded into `resume`. The engine reference is `?T` so
  /// `main.mo` can pass the raw `var internalEngine : ?...` field directly;
  /// `resume` returns `#err` early when it is null.
  public type ResumeDeps = {
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    secrets : SecretModel.SecretsState;
    internalEngine : ?InternalEngine.InternalEngine;
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    catalogState : WorkflowCatalogModel.CatalogState;
    approvalState : ApprovalModel.ApprovalState;
  };

  public type DispatchResult = {
    #ok : [Types.ProcessingStep];
    #err : { message : Text; steps : [Types.ProcessingStep] };
  };

  // ── start ──────────────────────────────────────────────────────────────────

  /// Dispatch a fresh-start agent turn by category.
  public func start(
    agent : AgentModel.AgentRecord,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    sourceRef : ?SessionModel.SourceRef,
    triggerMessageText : ?Text,
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
    slackUserId : ?Text,
    secrets : SecretModel.SecretsState,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    engineDeps : Types.AgentEngineDeps<ExecutionEnvelopeModel.EnvelopeState>,
    approvalState : ApprovalModel.ApprovalState,
  ) : async Types.AgentOrchestrateResult {
    let apiKey = switch (
      SecretModel.resolveSecret(
        secrets,
        agent,
        agent.ownedBy,
        #openRouterApiKey,
        workspaceKey,
        orgKey,
        { slackUserId; agentId = ?agent.id; operation = "agent-runner:start" },
      )
    ) {
      case (null) {
        return #err({
          message = "No OpenRouter API key found for agent. Please store the API key first.";
          steps = [];
        });
      };
      case (?key) { key };
    };

    let (channelId, threadTs) : (Text, ?Text) = switch (sourceRef) {
      case (?#slack({ channelId; ts = _; threadTs })) { (channelId, threadTs) };
      case (_) { ("", null) };
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
          approvalState,
          sourceRef,
          null, // resumeOverride: null for a fresh start
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

  // ── resume ─────────────────────────────────────────────────────────────────

  /// Resume the admin agent loop after an engine-completion async effect.
  /// Called from the `resumeAdminTurn` closure in main.mo.
  public func resume(
    deps : ResumeDeps,
    keyCache : KeyDerivationService.KeyCache,
    turnId : Text,
    suspension : SessionModel.SuspensionData,
    syntheticToolResult : Text,
  ) : async Types.AgentOrchestrateResult {
    let engine = switch (deps.internalEngine) {
      case (?e) { e };
      case null {
        return #err({
          message = "AgentRunner.resume: internal engine not initialized";
          steps = [];
        });
      };
    };

    let resolveDeps = {
      sessionStores = deps.sessionStores;
      agentRegistry = deps.agentRegistry;
      secrets = deps.secrets;
    };
    let ctx = switch (await TurnContextService.asyncResolve(resolveDeps, keyCache, turnId, null)) {
      case (#err({ message; stage = _ })) {
        return #err({ message = "AgentRunner.resume: " # message; steps = [] });
      };
      case (#ok(c)) { c };
    };
    let syncCtx = TurnContextService.syncResolve(resolveDeps, ctx, turnId);

    // "Workflow result" prefix distinguishes the final outcome from the interim dispatch signal.
    let syntheticMsg : OpenRouterWrapper.ResponseInputMessage = {
      role = #assistant;
      content = "Workflow result for call " # suspension.pendingToolCallId # ":\n" # syntheticToolResult # "\n\n";
    };

    let resumeMessages = Array.concat(suspension.messages, [syntheticMsg]);
    let assembled : ContextAssembler.AssembledContext = {
      messages = resumeMessages;
      stats = { summaryTokens = 0; rawTurnsIncluded = 0; channelSnippets = 0 };
    };

    await AdminAgentLoop.process(
      syncCtx.agent,
      assembled,
      turnId,
      syncCtx.turn.userAuthContext,
      ctx.apiKey,
      deps.secrets,
      ctx.workspaceKey,
      syncCtx.resolveSlackBotToken,
      {
        envelopeState = deps.envelopeState;
        internalEngine = engine;
        catalogState = deps.catalogState;
      },
      deps.approvalState,
      ctx.sourceRef,
      ?{ messages = resumeMessages; startRound = suspension.roundCount },
    );
  };

  // ── resumeWithApproval ────────────────────────────────────────────────────

  /// Dispatch the approved workflow and leave the original turn waiting for the
  /// engine completion event. The LLM resumes only from ExecutionAsyncEffectService.
  /// This replaces the deleted `ApprovalDispatchService.dispatchApproved`.
  public func resumeWithApproval(
    deps : ResumeDeps,
    keyCache : KeyDerivationService.KeyCache,
    approval : ApprovalModel.ApprovalRecord,
    slackUserId : Text,
    botTokenOpt : ?Text,
  ) : async DispatchResult {
    let engine = switch (deps.internalEngine) {
      case (?e) { e };
      case null {
        let msg = "Internal engine not initialized at approval dispatch.";
        return failTurnNoPost(deps, approval.turnId, msg);
      };
    };

    let resolveDeps = {
      sessionStores = deps.sessionStores;
      agentRegistry = deps.agentRegistry;
      secrets = deps.secrets;
    };
    let ctx = switch (
      await TurnContextService.asyncResolve(
        resolveDeps,
        keyCache,
        approval.turnId,
        ?slackUserId,
      )
    ) {
      case (#err({ message; stage = _ })) {
        let cost = SessionModel.aggregateTurnCost(deps.sessionStores, approval.turnId);
        SessionModel.completeTurn(deps.sessionStores, approval.turnId, #failed, cost, ?message);
        return #err({
          message;
          steps = [dispatchStep("approval_dispatch", #err(message))];
        });
      };
      case (#ok(c)) { c };
    };
    let syncCtx = TurnContextService.syncResolve(resolveDeps, ctx, approval.turnId);

    let (suspension, approvalCode) = switch (syncCtx.turn.status) {
      case (#awaitingApproval(data)) {
        (data.suspension, data.approvalCode);
      };
      case (_) {
        return await failTurn(
          deps,
          approval.turnId,
          botTokenOpt,
          ctx.channelId,
          ctx.threadTs,
          "Approval code was accepted, but the turn is no longer waiting for approval.",
        );
      };
    };

    if (approval.code != approvalCode) {
      return await failTurn(
        deps,
        approval.turnId,
        botTokenOpt,
        ctx.channelId,
        ctx.threadTs,
        "Approval record does not match the suspended turn.",
      );
    };

    let botToken = switch (botTokenOpt) {
      case (?token) { token };
      case null {
        return failTurnNoPost(deps, approval.turnId, "No Slack bot token for approval dispatch.");
      };
    };

    let descriptor = switch (await resolveDescriptor(deps.catalogState, engine, approval.workflowName)) {
      case (#ok(d)) { d };
      case (#err(message)) {
        return await failTurn(deps, approval.turnId, ?botToken, ctx.channelId, ctx.threadTs, message);
      };
    };

    let argsWithApproval = injectApprovalCode(approval.originalArgs, approval.code);
    let instructions = InstructionComposer.compose(
      AgentHelpers.categoryToRole(syncCtx.agent.category, syncCtx.agent.config.name),
      [],
      [],
    );

    let envelopeContext : ToolTypes.EnvelopeContext = {
      agent = syncCtx.agent;
      turnId = approval.turnId;
      instructions;
      messages = messagesToChat(suspension.messages);
      apiKey = ctx.apiKey;
    };

    let engineDispatch : ToolTypes.EngineDispatch = {
      envelopeState = deps.envelopeState;
      internalEngine = engine;
      catalogState = deps.catalogState;
      approvalState = deps.approvalState;
    };

    let dispatchResult = try {
      await WorkflowEngineHandler.handle(
        descriptor,
        engineDispatch,
        envelopeContext,
        ?syncCtx.resolveSlackBotToken,
        approval.requestedByUserId,
        ctx.sourceRef,
        argsWithApproval,
      );
    } catch (err : Error) {
      return await failTurn(
        deps,
        approval.turnId,
        ?botToken,
        ctx.channelId,
        ctx.threadTs,
        "Dispatch failed after approval: " # Error.message(err),
      );
    };

    switch (dispatchResult) {
      case (#err(errJson)) {
        await failTurn(
          deps,
          approval.turnId,
          ?botToken,
          ctx.channelId,
          ctx.threadTs,
          extractJsonMessage(errJson),
        );
      };
      case (#ok(resultJson)) {
        if (not isDispatched(resultJson)) {
          return await failTurn(
            deps,
            approval.turnId,
            ?botToken,
            ctx.channelId,
            ctx.threadTs,
            "Workflow was not dispatched after approval.",
          );
        };
        ignore SessionModel.suspendForWorkflow(deps.sessionStores, approval.turnId, suspension);
        #ok([dispatchStep("approval_dispatch", #ok)]);
      };
    };
  };

  // ── Private helpers ───────────────────────────────────────────────────────

  private func resolveDescriptor(
    catalogState : WorkflowCatalogModel.CatalogState,
    engine : InternalEngine.InternalEngine,
    workflowName : Text,
  ) : async { #ok : WorkflowCatalogTypes.WorkflowDescriptor; #err : Text } {
    if (catalogState.cached == null) {
      switch (await WorkflowCatalogService.refreshCatalog(catalogState, engine)) {
        case (#ok) {};
        case (#err(message)) {
          return #err("Workflow catalog unavailable at approval dispatch: " # message);
        };
      };
    };
    switch (catalogState.cached) {
      case (?{ descriptors; catalogHash = _ }) {
        switch (Array.find<WorkflowCatalogTypes.WorkflowDescriptor>(descriptors, func(d) { d.workflowName == workflowName })) {
          case (?descriptor) { #ok(descriptor) };
          case null {
            #err("Workflow '" # workflowName # "' not found in catalog.");
          };
        };
      };
      case null { #err("Workflow catalog unavailable at approval dispatch.") };
    };
  };

  private func injectApprovalCode(args : Text, approvalCode : Text) : Text {
    switch (Json.parse(args)) {
      case (#err(_)) { args };
      case (#ok(parsed)) {
        let updated = switch (parsed) {
          case (#object_(fields)) {
            let filtered = Array.filter<(Text, Json.Json)>(
              fields,
              func((key, _) : (Text, Json.Json)) : Bool {
                key != "approvalCode";
              },
            );
            #object_(Array.concat(filtered, [("approvalCode", #string(approvalCode))]));
          };
          case (_) { parsed };
        };
        Json.stringify(updated, null);
      };
    };
  };

  private func isDispatched(resultJson : Text) : Bool {
    switch (Json.parse(resultJson)) {
      case (#ok(json)) {
        switch (Json.get(json, "dispatched")) {
          case (?#bool(true)) { true };
          case (_) { false };
        };
      };
      case (#err(_)) { false };
    };
  };

  private func extractJsonMessage(errJson : Text) : Text {
    switch (Json.parse(errJson)) {
      case (#ok(json)) {
        switch (Json.get(json, "message")) {
          case (?#string(message)) { message };
          case (_) { errJson };
        };
      };
      case (#err(_)) { errJson };
    };
  };

  private func messagesToChat(
    messages : [OpenRouterWrapper.ResponseInputMessage]
  ) : [ExecutionTypes.ChatMessage] {
    Array.map<OpenRouterWrapper.ResponseInputMessage, ExecutionTypes.ChatMessage>(
      messages,
      func(message : OpenRouterWrapper.ResponseInputMessage) : ExecutionTypes.ChatMessage {
        { role = message.role; content = message.content };
      },
    );
  };

  private func failTurn(
    deps : ResumeDeps,
    turnId : Text,
    botTokenOpt : ?Text,
    channelId : Text,
    threadTs : ?Text,
    message : Text,
  ) : async DispatchResult {
    switch (botTokenOpt) {
      case (?botToken) {
        ignore await SlackWrapper.postMessage(botToken, channelId, "[Agent error] " # message, threadTs, null, null);
      };
      case null {};
    };
    failTurnNoPost(deps, turnId, message);
  };

  private func failTurnNoPost(deps : ResumeDeps, turnId : Text, message : Text) : DispatchResult {
    let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
    SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?message);
    #err({ message; steps = [dispatchStep("approval_dispatch", #err(message))] });
  };

  private func dispatchStep(action : Text, result : { #ok; #err : Text }) : Types.ProcessingStep {
    { action; result; timestamp = Time.now() };
  };

  // ── resumeWithDenial ───────────────────────────────────────────────────────────────────────

  /// Resume the admin agent loop after a workflow approval was denied or timed out.
  /// Injects a synthetic denial tool result so the LLM can acknowledge and react.
  ///
  /// Called from the TTL expiry timer or from block-actions-handler (via a zero-delay
  /// timer to stay within Slack's 3-second interactive-payload response window).
  /// The timer must be cancelled by the caller BEFORE calling this function.
  public func resumeWithDenial(
    deps : ResumeDeps,
    keyCache : KeyDerivationService.KeyCache,
    turnId : Text,
    reason : Text,
    botTokenOpt : ?Text,
  ) : async () {
    let engine = switch (deps.internalEngine) {
      case (?e) { e };
      case null {
        Logger.log(#error, ?"AgentRunner", "resumeWithDenial: engine not initialized for turn " # turnId);
        ignore failTurnNoPost(deps, turnId, "Internal engine not initialized at denial resume.");
        return;
      };
    };

    let resolveDeps = {
      sessionStores = deps.sessionStores;
      agentRegistry = deps.agentRegistry;
      secrets = deps.secrets;
    };

    let ctx = switch (await TurnContextService.asyncResolve(resolveDeps, keyCache, turnId, null)) {
      case (#err({ message; stage = _ })) {
        Logger.log(#error, ?"AgentRunner", "resumeWithDenial context failed for turn " # turnId # ": " # message);
        ignore failTurnNoPost(deps, turnId, message);
        return;
      };
      case (#ok(c)) { c };
    };
    let syncCtx = TurnContextService.syncResolve(resolveDeps, ctx, turnId);

    // Race guard: if the turn is no longer awaiting approval (concurrent button click),
    // the denial has already been handled — no-op.
    // resumeFromApproval atomically checks #awaitingApproval and flips to #running.
    let suspension = switch (SessionModel.resumeFromApproval(deps.sessionStores, turnId)) {
      case (#ok({ suspension; approvalCode = _ })) {
        suspension;
      };
      case (#err(_)) { return };
    };

    let botToken = switch (botTokenOpt) {
      case (?t) { t };
      case null {
        switch (syncCtx.resolveSlackBotToken("denial_resume")) {
          case (?t) { t };
          case null {
            ignore failTurnNoPost(deps, turnId, "No Slack bot token for denial resume.");
            return;
          };
        };
      };
    };

    // Build a synthetic denial result; "Workflow result" prefix matches the engine-resume path.
    let syntheticResult = "{\"dispatched\":false,\"denied\":true,\"reason\":" # Json.stringify(#string(reason), null) # "}";
    let syntheticMsg : OpenRouterWrapper.ResponseInputMessage = {
      role = #assistant;
      content = "Workflow result for call " # suspension.pendingToolCallId # ":\n" # syntheticResult # "\n\n";
    };

    let resumeMessages = Array.concat(suspension.messages, [syntheticMsg]);

    let loopResult = try {
      await AdminAgentLoop.process(
        syncCtx.agent,
        {
          messages = resumeMessages;
          stats = {
            summaryTokens = 0;
            rawTurnsIncluded = 0;
            channelSnippets = 0;
          };
        },
        turnId,
        syncCtx.turn.userAuthContext,
        ctx.apiKey,
        deps.secrets,
        ctx.workspaceKey,
        syncCtx.resolveSlackBotToken,
        {
          envelopeState = deps.envelopeState;
          internalEngine = engine;
          catalogState = deps.catalogState;
        },
        deps.approvalState,
        ctx.sourceRef,
        ?{ messages = resumeMessages; startRound = suspension.roundCount },
      );
    } catch (err : Error) {
      ignore await failTurn(deps, turnId, ?botToken, ctx.channelId, ctx.threadTs, "Denial resume failed: " # Error.message(err));
      return;
    };

    // Build reply metadata for the Slack post.
    let (parentTs, parentChannel) = switch (ctx.sourceRef) {
      case (?#slack({ channelId; ts; threadTs = _ })) { (ts, channelId) };
      case _ { ("", ctx.channelId) };
    };
    let metadata : ?Types.AgentMessageMetadata = ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = syncCtx.agent.config.name;
        parent_ts = parentTs;
        parent_channel = parentChannel;
        turn_id = turnId;
      };
    };

    switch (loopResult) {
      case (#ok(_) or #err(_)) {
        ignore await TurnCompletionService.complete(
          { sessionStores = deps.sessionStores },
          turnId,
          loopResult,
          {
            botToken;
            channelId = ctx.channelId;
            threadTs = ctx.threadTs;
            metadata;
          },
        );
      };
      case (#dispatched(_) or #awaitingApproval(_)) {
        ignore TurnSuspensionService.suspend(
          {
            sessionStores = deps.sessionStores;
            approvalState = deps.approvalState;
          },
          turnId,
          loopResult,
        );
      };
    };
  };
};
