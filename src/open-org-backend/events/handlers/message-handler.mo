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
///   5. Resolve the primary agent, then dispatch via AgentRouter (Phase 1.6).
///   6. Run similarity check (bot path only) to detect stuck loops (Phase 1.6).
///   7. Post the reply back to Slack via SlackWrapper (with agentMetadata for lineage).
///
/// Note: the bot reply is NOT explicitly stored here — Slack echoes the posted
/// message back as a bot event, which is stored via the normal incoming-message
/// path (step 2), ensuring exactly one write per reply.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Types "../../types";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ConversationModel "../../models/conversation-model";
import ValueStreamModel "../../models/value-stream-model";
import ObjectiveModel "../../models/objective-model";
import AgentRouter "../agent-router";
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
  /// #skip                → short-circuit: return this result immediately.
  /// #skipWithTermination → short-circuit AND post a termination prompt in handle().
  ///                         Emitted when MAX_AGENT_ROUNDS is hit — the sync round
  ///                         tracker cannot await, so it delegates prompt delivery
  ///                         to the async handle() function.
  /// #proceed             → continue orchestration with the derived auth context.
  type RoundResult = {
    #skip : NormalizedEventTypes.HandlerResult;
    #skipWithTermination : NormalizedEventTypes.HandlerResult; // post prompt before returning
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
    // Return #skipWithTermination so the async handle() can call postTerminationPrompt.
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
      return #skipWithTermination(#ok([{ action = "round_force_terminated"; result = #err("max agent rounds reached"); timestamp = Time.now() }]));
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
  ///
  /// `parent_agent` is always `"::" # primaryAgent.name` — the agent that produced
  /// this reply.  Any subsequent message referencing this reply will therefore
  /// be routed to the same agent category.
  func buildReplyMetadata(
    channel : Text,
    ts : Text,
    primaryAgent : AgentModel.AgentRecord,
  ) : ?Types.AgentMessageMetadata {
    ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = "::" # primaryAgent.name;
        parent_ts = ts;
        parent_channel = channel;
      };
    };
  };

  /// Resolve the primary agent for this message event.
  ///
  /// Bot message  → look up the agent named in `agentMetadata.event_payload.parent_agent`
  ///                (strip leading "::" before the registry lookup).
  ///                Returns null (discard) if the agent is not found in the registry.
  ///
  /// User message → take the first valid `::agentname` reference in the message text;
  ///                if none, fall back to the first registered `#admin` agent.
  ///                Returns null if no agent can be resolved at all.
  func resolvePrimaryAgent(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : ?AgentModel.AgentRecord {
    if (msg.isBotMessage) {
      // Bot path: primary agent comes from the metadata that was embedded when the
      // reply was originally posted — it is the agent that authored that reply.
      let agentMeta = switch (msg.agentMetadata) {
        case (null) { Runtime.unreachable() }; // guard: should have been caught earlier
        case (?m) { m };
      };
      let name = agentMeta.event_payload.parent_agent;
      switch (AgentModel.lookupByName(name, ctx.agentRegistry)) {
        case (null) {
          Logger.log(
            #warn,
            ?"MessageHandler",
            "Primary agent '" # name # "' not found in registry — discarding bot event",
          );
          null;
        };
        case (?agent) { ?agent };
      };
    } else {
      // User path: prefer an explicit ::agentname reference; fall back to first #admin.
      let validAgents = AgentRefParser.extractValidAgents(msg.text, ctx.agentRegistry);
      if (validAgents.size() > 0) {
        ?validAgents[0];
      } else {
        switch (AgentModel.getFirstByCategory(#admin, ctx.agentRegistry)) {
          case (null) {
            Logger.log(#warn, ?"MessageHandler", "No #admin agent registered — cannot handle user message");
            null;
          };
          case (?agent) { ?agent };
        };
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
      {
        ts = msg.ts;
        userAuthContext = null;
        text = msg.text;
        agentMetadata = switch (msg.agentMetadata) {
          case (?m) { ?m.event_payload };
          case null { null };
        };
      },
      msg.threadTs,
    );

    // ── Phase 1.5 — Round tracking + pre-condition guards ─────────────────────
    //
    // `activeCtxOpt` is applied to the persisted message (step 8) so the chain
    // can be reconstructed by future rounds via getMessage + agentMetadata.
    let activeCtxOpt : ?SlackAuthMiddleware.UserAuthContext = switch (resolveRoundContext(msg, ctx)) {
      case (#skip(result)) { return result };
      case (#skipWithTermination(result)) {
        // Post the termination prompt here where await is available (best-effort).
        switch (SecretModel.getSecretScoped(Map.get(ctx.secrets, Nat.compare, workspaceId), await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId), #slackBotToken)) {
          case (?tok) {
            await AgentRouter.postTerminationPrompt(tok, msg.channel, msg.threadTs);
          };
          case (null) {};
        };
        return result;
      };
      case (#proceed(ctxOpt)) { ctxOpt };
    };

    // Update ConversationMessage with the incremented auth context (new round starts).
    ignore ConversationModel.updateMessageContext(ctx.conversationStore, msg.channel, rootTs, msg.ts, activeCtxOpt);

    // ── Phase 1.6 — Resolve primary agent ────────────────────────────────────
    //
    // Bot message  → agent that authored the reply (from agentMetadata.parent_agent).
    // User message → first ::agentname reference in text, or first #admin agent.
    let primaryAgent : AgentModel.AgentRecord = switch (resolvePrimaryAgent(msg, ctx)) {
      case (null) {
        Logger.log(#warn, ?"MessageHandler", "No primary agent resolved — discarding event");
        return #ok([{
          action = "primary_agent_skip";
          result = #err("no primary agent found");
          timestamp = Time.now();
        }]);
      };
      case (?agent) { agent };
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

    // 4. Dispatch via AgentRouter.
    let orchestratorResult = await AgentRouter.route(
      primaryAgent,
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

    // 6. Similarity check (bot path only) — gates the Slack post.
    //    Walk the parentRef chain to find a prior reply from the same agent;
    //    if one exists and the new reply is too similar, force-terminate and
    //    post a prompt instead of echoing the near-duplicate.
    switch (msg.agentMetadata) {
      case (?agentMeta) {
        switch (
          AgentRouter.findPreviousSameAgentReply(
            ctx.conversationStore,
            agentMeta.event_payload.parent_channel,
            agentMeta.event_payload.parent_ts,
            primaryAgent.name,
          )
        ) {
          case (null) {}; // No prior reply from this agent — proceed.
          case (?prevReply) {
            if (AgentRouter.isSimilar(replyText, prevReply.text)) {
              Logger.log(
                #warn,
                ?"MessageHandler",
                "Similarity loop detected for agent ::" # primaryAgent.name # " — force-terminating session",
              );
              let terminatedCtx = switch (activeCtxOpt) {
                case (null) { null };
                case (?ctx_) {
                  ?SlackAuthMiddleware.withRound(ctx_, ctx_.roundCount, true, ctx_.parentRef);
                };
              };
              ignore ConversationModel.updateMessageContext(
                ctx.conversationStore,
                msg.channel,
                rootTs,
                msg.ts,
                terminatedCtx,
              );
              await AgentRouter.postTerminationPrompt(botToken, msg.channel, msg.threadTs);
              return #ok(
                Array.concat(
                  llmSteps,
                  [{
                    action = "round_similarity_terminated";
                    result = #err("similar reply detected — session force-terminated");
                    timestamp = Time.now();
                  }],
                )
              );
            };
          };
        };
      };
      case (null) {}; // User message — no similarity check.
    };

    // 7. Post reply to Slack with round-chain metadata.
    let replyMetadata = buildReplyMetadata(msg.channel, msg.ts, primaryAgent);
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
