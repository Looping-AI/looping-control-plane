/// Message Handler
/// Handles standard user messages, me_messages, and own-bot agent messages.
///
/// Acts as a controller for the message event:
///   1. Round tracking (Phase 1.5):
///      - User message  → build a fresh UserAuthContext (roundCount = 0, parentRef = null)
///                        and persist it on the ConversationMessage.
///      - Bot message   → resolve the parent ConversationMessage via agentMetadata,
///                        inherit its UserAuthContext, apply pre-condition guards,
///                        then derive a new context with roundCount + 1.
///      No separate round-context index is used; lineage is carried in agentMetadata
///      and the roundCount is stored on each ConversationMessage.userAuthContext.
///   2. Persist the incoming message to the conversation store (Phase 1.4).
///   3. Scope workspace data from EventProcessingContext.
///   4. Derive the workspace encryption key (once).
///   5. Call WorkspaceAdminOrchestrator for LLM reply.
///   6. Persist the agent's response to the conversation store (Phase 1.4).
///   7. Post the reply back to Slack via SlackWrapper (with agentMetadata for lineage).

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Types "../../types";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ConversationModel "../../models/conversation-model";
import ValueStreamModel "../../models/value-stream-model";
import ObjectiveModel "../../models/objective-model";
import WorkspaceAdminOrchestrator "../../orchestrators/workspace-admin-orchestrator";
import SlackWrapper "../../wrappers/slack-wrapper";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import AgentRefParser "../../utilities/agent-ref-parser";
import AgentModel "../../models/agent-model";
import Constants "../../constants";
import Logger "../../utilities/logger";
import WorkspaceModel "../../models/workspace-model";

module {

  // ─── Types ───────────────────────────────────────────────────────────────────

  /// Convenience alias for the incoming message shape.
  type IncomingMsg = {
    user : Text;
    text : Text;
    channel : Text;
    ts : Text;
    threadTs : ?Text;
    isBotMessage : Bool;
    agentMetadata : ?Types.AgentMessageMetadata;
  };

  /// Result of round-context resolution.
  /// #skip   → short-circuit: return this result immediately from the handler.
  /// #proceed → continue orchestration with the derived (possibly null) auth context.
  type RoundResult = {
    #skip : NormalizedEventTypes.HandlerResult;
    #proceed : ?SlackAuthMiddleware.UserAuthContext;
  };

  // ─── Private helpers ─────────────────────────────────────────────────────────

  /// Resolve the workspace ID from the channel.
  /// Returns 0 for the implicit "org" workspace when the channel has no explicit anchor.
  func resolveWorkspaceId(
    channel : Text,
    workspaces : WorkspaceModel.WorkspacesState,
  ) : Nat {
    switch (WorkspaceModel.resolveWorkspaceByChannel(workspaces, channel)) {
      case (#adminChannel(wsId)) { wsId };
      case (#memberChannel(wsId)) { wsId };
      case (#none) { 0 };
    };
  };

  /// Phase 1.5 — Dispatch to the bot or user round-tracking path.
  func resolveRoundContext(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : RoundResult {
    if (msg.isBotMessage) {
      resolveBotRoundContext(msg, ctx);
    } else {
      resolveUserRoundContext(msg, ctx);
    };
  };

  /// Bot message path — inherit the parent UserAuthContext, enforce guards, advance round.
  func resolveBotRoundContext(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : RoundResult {
    // Guard: message must reference at least one valid ::agentname.
    let validAgents = AgentRefParser.extractValidAgents(msg.text, ctx.agentRegistry);
    if (validAgents.size() == 0) {
      Logger.log(#info, ?"MessageHandler", "No valid ::agentname reference in bot message — discarding event");
      return #skip(#ok([{ action = "round_skip"; result = #err("no valid agent reference"); timestamp = Time.now() }]));
    };

    // Guard: agentMetadata must be present (adapter enforces this; defensive check).
    let agentMeta = switch (msg.agentMetadata) {
      case (null) {
        Logger.log(#warn, ?"MessageHandler", "Bot message missing agentMetadata — skipping");
        return #skip(#ok([{ action = "round_skip"; result = #err("bot message missing agentMetadata"); timestamp = Time.now() }]));
      };
      case (?m) { m };
    };

    // Guard: parent message must exist in the conversation store.
    let parentMsg = switch (
      ConversationModel.getMessage(
        ctx.conversationStore,
        agentMeta.event_payload.parent_channel,
        agentMeta.event_payload.parent_ts,
      )
    ) {
      case (null) {
        Logger.log(
          #info,
          ?"MessageHandler",
          "Parent message not found: channel=" # agentMeta.event_payload.parent_channel #
          " ts=" # agentMeta.event_payload.parent_ts # " — discarding orphaned bot message",
        );
        return #skip(#ok([{ action = "round_skip"; result = #err("parent message not found in store"); timestamp = Time.now() }]));
      };
      case (?m) { m };
    };

    // Guard: parent must carry a UserAuthContext (lineage must be intact).
    let parentCtx = switch (parentMsg.userAuthContext) {
      case (null) {
        Logger.log(#info, ?"MessageHandler", "Parent message has no userAuthContext — discarding bot message");
        return #skip(#ok([{ action = "round_skip"; result = #err("parent message has no userAuthContext"); timestamp = Time.now() }]));
      };
      case (?c) { c };
    };

    // Guard: session must not have been force-terminated.
    if (parentCtx.forceTerminated) {
      Logger.log(#info, ?"MessageHandler", "Session force-terminated — discarding bot message");
      return #skip(#ok([{ action = "round_skip"; result = #err("session force-terminated"); timestamp = Time.now() }]));
    };

    let newRound = parentCtx.roundCount + 1;
    let newParentRef : ?{ channelId : Text; ts : Text } = ?{
      channelId = agentMeta.event_payload.parent_channel;
      ts = agentMeta.event_payload.parent_ts;
    };

    // Hard ceiling: force-terminate, stamp the terminated context, and stop.
    if (newRound >= Constants.MAX_AGENT_ROUNDS) {
      let terminatedCtx = SlackAuthMiddleware.withRound(parentCtx, newRound, true, newParentRef);
      let msgRootTs = switch (msg.threadTs) {
        case (?ts) { ts };
        case (null) { msg.ts };
      };
      ignore ConversationModel.updateMessageContext(
        ctx.conversationStore,
        msg.channel,
        msgRootTs,
        msg.ts,
        ?terminatedCtx,
      );
      Logger.log(
        #warn,
        ?"MessageHandler",
        "MAX_AGENT_ROUNDS (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ") reached — force-terminating session",
      );
      // Phase 1.6 will post a continuation prompt to Slack here.
      return #skip(#ok([{ action = "round_force_terminated"; result = #err("max agent rounds reached"); timestamp = Time.now() }]));
    };

    // Advance the round context and fall through to orchestration.
    let activeCtx = SlackAuthMiddleware.withRound(parentCtx, newRound, false, newParentRef);
    Logger.log(
      #info,
      ?"MessageHandler",
      "Bot message round " # Nat.toText(newRound) #
      " | parent: " # agentMeta.event_payload.parent_ts #
      " | user: " # activeCtx.slackUserId #
      " | agent(s): " # debug_show (Array.map<AgentModel.AgentRecord, Text>(validAgents, func(a) { a.name })),
    );
    // Phase 1.6 (Agent Router) will replace the fall-through with category-aware routing.
    #proceed(?activeCtx);
  };

  /// User message path — build a fresh UserAuthContext (roundCount = 0, parentRef = null).
  func resolveUserRoundContext(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : RoundResult {
    switch (SlackAuthMiddleware.buildFromCache(msg.user, ctx.slackUsers.cache)) {
      case (null) {
        // User not in cache yet (e.g. cache not yet populated) — proceed without auth context.
        Logger.log(
          #warn,
          ?"MessageHandler",
          "Slack user " # msg.user # " not found in cache — no userAuthContext for message " # msg.ts,
        );
        #proceed(null);
      };
      case (?userCtx) {
        Logger.log(
          #info,
          ?"MessageHandler",
          "UserAuthContext built for " # msg.user # " | message: " # msg.ts,
        );
        #proceed(?userCtx);
      };
    };
  };

  /// Scope all workspace-specific state from the EventProcessingContext.
  func scopeWorkspaceData(
    ctx : EventProcessingContextTypes.EventProcessingContext,
    workspaceId : Nat,
  ) : {
    workspaceSecrets : ?Map.Map<Types.SecretId, SecretModel.EncryptedSecret>;
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState;
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap;
  } {
    let workspaceSecrets = Map.get(ctx.secrets, Nat.compare, workspaceId);
    let workspaceValueStreamsState = switch (Map.get(ctx.workspaceValueStreams, Nat.compare, workspaceId)) {
      case (?state) { state };
      case (null) { ValueStreamModel.emptyWorkspaceState() };
    };
    let workspaceObjectivesMap = switch (Map.get(ctx.workspaceObjectives, Nat.compare, workspaceId)) {
      case (?objMap) { objMap };
      case (null) {
        Map.empty<Nat, ObjectiveModel.ValueStreamObjectivesState>();
      };
    };
    { workspaceSecrets; workspaceValueStreamsState; workspaceObjectivesMap };
  };

  /// Build the AgentMessageMetadata attached to every outbound Slack message,
  /// which allows future bot events to trace back through the round chain.
  func buildReplyMetadata(
    channel : Text,
    ts : Text,
    msgText : Text,
    agentRegistry : AgentModel.AgentRegistryState,
  ) : ?Types.AgentMessageMetadata {
    let validAgents = AgentRefParser.extractValidAgents(msgText, agentRegistry);
    let parentAgentName : Text = if (validAgents.size() > 0) {
      "::" # validAgents[0].name;
    } else {
      "::admin" // fallback during Phase 1.5 — Phase 1.6 Agent Router will use the actual agent
    };
    ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = parentAgentName;
        parent_ts = ts;
        parent_channel = channel;
      };
    };
  };

  // ─── Public entry point ──────────────────────────────────────────────────────

  public func handle(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {

    // Resolve workspace from the channel — the handler owns this resolution.
    let workspaceId = resolveWorkspaceId(msg.channel, ctx.workspaces);

    // ── Phase 1.4 — Persist incoming message immediately ──────────────────────
    //
    // rootTs is needed both for the conversation-entry fetch and for the later
    // updateMessageContext call; compute it once here.
    let rootTs = switch (msg.threadTs) {
      case (?ts) { ts };
      case (null) { msg.ts };
    };
    // Fetch the conversation entry BEFORE storing the incoming message so the
    // LLM context does not see the same message twice.
    let conversationEntry = ConversationModel.getEntry(ctx.conversationStore, msg.channel, rootTs);

    // Every inbound message event is stored immediately with a null auth context;
    // the context is stamped via updateMessageContext once round tracking resolves.
    ConversationModel.addMessage(
      ctx.conversationStore,
      msg.channel,
      { ts = msg.ts; userAuthContext = null; text = msg.text },
      msg.threadTs,
    );

    // ── Phase 1.5 — Round tracking + pre-condition guards ─────────────────────
    //
    // `activeCtxOpt` is applied to the persisted message (step 7) so the chain
    // can be reconstructed by future rounds via getMessage + agentMetadata.
    let activeCtxOpt : ?SlackAuthMiddleware.UserAuthContext = switch (resolveRoundContext(msg, ctx)) {
      case (#skip(result)) { return result };
      case (#proceed(ctxOpt)) { ctxOpt };
    };

    // ── Orchestration (shared path for user and bot messages) ─────────────────

    // 1. Scope workspace data.
    let { workspaceSecrets; workspaceValueStreamsState; workspaceObjectivesMap } = scopeWorkspaceData(ctx, workspaceId);

    // 2. Derive the workspace encryption key (once per event).
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);

    // 3. Decrypt the Slack bot token.
    let botToken = switch (SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, #slackBotToken)) {
      case (null) {
        Logger.log(
          #warn,
          ?"MessageHandler",
          "No Slack bot token found for workspace " # debug_show (workspaceId),
        );
        return #ok([{
          action = "post_to_slack";
          result = #err("No Slack bot token configured for workspace");
          timestamp = Time.now();
        }]);
      };
      case (?token) { token };
    };

    // 4. Call the orchestrator.
    let orchestratorResult = await WorkspaceAdminOrchestrator.orchestrateAdminTalk(
      ctx.agentRegistry,
      ctx.mcpToolRegistry,
      workspaceSecrets,
      conversationEntry,
      workspaceValueStreamsState,
      ctx.workspaceValueStreams,
      workspaceObjectivesMap,
      ctx.metricsRegistry,
      ctx.metricDatapoints,
      workspaceId,
      msg.text,
      encryptionKey,
    );

    // 5. Extract LLM steps and reply text.
    let (llmSteps, replyTextOpt) : ([Types.ProcessingStep], ?Text) = switch (orchestratorResult) {
      case (#err({ message = _; steps })) { (steps, null) };
      case (#ok({ response; steps })) { (steps, ?response) };
    };

    let replyText = switch (replyTextOpt) {
      case (null) {
        Logger.log(
          #warn,
          ?"MessageHandler",
          "No assistant reply generated for workspace " # debug_show (workspaceId),
        );
        return #ok(llmSteps);
      };
      case (?text) { text };
    };

    // 6. Stamp the persisted message with the resolved auth context.
    ignore ConversationModel.updateMessageContext(ctx.conversationStore, msg.channel, rootTs, msg.ts, activeCtxOpt);

    // 7. Post reply to Slack with round-chain metadata.
    let replyMetadata = buildReplyMetadata(msg.channel, msg.ts, msg.text, ctx.agentRegistry);
    let slackResult = await SlackWrapper.postMessage(botToken, msg.channel, replyText, msg.threadTs, replyMetadata);
    let slackStep : Types.ProcessingStep = {
      action = "post_to_slack";
      result = switch (slackResult) {
        case (#ok(_)) { #ok };
        case (#err(e)) { #err(e) };
      };
      timestamp = Time.now();
    };

    #ok(Array.concat(llmSteps, [slackStep]));
  };
};
