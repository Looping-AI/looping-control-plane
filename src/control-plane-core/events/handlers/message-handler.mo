/// Message Handler
/// Handles standard user messages, me_messages, and own-bot agent messages.
///
/// The public `handle` function is a thin orchestration sequence that delegates
/// each discrete responsibility to a private helper:
///
///   Phase 1.4  persistIncomingMessage  — fetch LLM context entry, then store the
///                                        incoming message with a null auth context.
///   Phase 1.5  resolveRoundContext     — enforce delegation-depth guards via
///                                        SessionModel.countDelegationDepth.
///              postTerminationIfTokenAvailable — post the ceiling prompt when
///                                        the delegation depth limit is hit.
///   Phase 1.6  resolvePrimaryAgent     — pick the agent to route to.
///              channelGuard            — reject messages from channels the agent
///                                        is not configured for.
///              postAgentReply          — post the reply to Slack and emit the final
///                                        HandlerResult.
///
/// Helper inventory (sync):
///   resolveWorkspaceId, rootTimestamp, persistIncomingMessage,
///   resolveRoundContext → resolveBotRoundContext / resolveUserRoundContext,
///   buildReplyMetadata, resolvePrimaryAgent
///
/// Helper inventory (async):
///   postTerminationIfTokenAvailable, postAgentReply
///
/// Note: the bot reply is NOT explicitly stored here — Slack echoes the posted
/// message back as a bot event, which is stored via the normal incoming-message
/// path (persistIncomingMessage), ensuring exactly one write per reply.

import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Types "../../types";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ChannelHistoryModel "../../models/channel-history-model";
import AgentOrchestrator "../../agents/agent-orchestrator";
import SlackWrapper "../../wrappers/slack-wrapper";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import AgentRefParser "../../utilities/agent-ref-parser";
import AgentModel "../../models/agent-model";
import Constants "../../constants";
import Logger "../../utilities/logger";
import WorkspaceModel "../../models/workspace-model";
import SessionModel "../../models/session-model";

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
  /// #proceed             → continue orchestration with the derived auth context
  ///                         and the triggerTurnId for delegation chaining.
  type RoundResult = {
    #skip : NormalizedEventTypes.HandlerResult;
    #skipWithTermination : NormalizedEventTypes.HandlerResult;
    #proceed : {
      authCtx : ?SlackAuthMiddleware.UserAuthContext;
      triggerTurnId : ?Text;
    };
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

  /// Bot message path — inherit the parent UserAuthContext, enforce guards, check delegation depth.
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

    // Guard: parent message must exist in the channel history store.
    let parentMsg = switch (
      ChannelHistoryModel.getMessage(
        ctx.channelHistory,
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

    // Extract the triggerTurnId from the metadata (links this delegation to its parent turn).
    let triggerTurnId : ?Text = ?agentMeta.event_payload.turn_id;

    // Guard: delegation depth must not exceed MAX_AGENT_ROUNDS.
    let depth = SessionModel.countDelegationDepth(ctx.sessionStores, triggerTurnId, Constants.MAX_AGENT_ROUNDS);
    if (depth >= Constants.MAX_AGENT_ROUNDS) {
      Logger.log(
        #warn,
        ?"MessageHandler",
        "MAX_AGENT_ROUNDS (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ") reached — force-terminating session",
      );
      return #skipWithTermination(#ok([{ action = "round_force_terminated"; result = #err("max agent rounds reached"); timestamp = Time.now() }]));
    };

    Logger.log(
      #info,
      ?"MessageHandler",
      "Bot message delegation depth " # Nat.toText(depth) #
      " | parent: " # agentMeta.event_payload.parent_ts #
      " | user: " # parentCtx.slackUserId #
      " | agent(s): " # debug_show (Array.map<AgentModel.AgentRecord, Text>(validAgents, func(a) { a.config.name })),
    );
    #proceed({ authCtx = ?parentCtx; triggerTurnId });
  };

  /// User message path — build a fresh UserAuthContext. No delegation chain (triggerTurnId = null).
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
        #proceed({ authCtx = null; triggerTurnId = null });
      };
      case (?userCtx) {
        Logger.log(
          #info,
          ?"MessageHandler",
          "UserAuthContext built for " # msg.user # " | message: " # msg.ts,
        );
        #proceed({ authCtx = ?userCtx; triggerTurnId = null });
      };
    };
  };

  /// Build the AgentMessageMetadata attached to every outbound Slack message,
  /// which allows future bot events to trace back through the round chain.
  ///
  /// `parent_agent` is the bare agent name (no `::` prefix).
  /// Any subsequent message referencing this reply will therefore
  /// be routed to the same agent category.
  func buildReplyMetadata(
    channel : Text,
    ts : Text,
    primaryAgent : AgentModel.AgentRecord,
    turnId : Text,
  ) : ?Types.AgentMessageMetadata {
    ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = primaryAgent.config.name;
        parent_ts = ts;
        parent_channel = channel;
        turn_id = turnId;
      };
    };
  };

  /// Resolve the primary agent for this message event.
  ///
  /// Bot message  → look up the agent named in `agentMetadata.event_payload.parent_agent`
  ///                (bare name, no `::` prefix).
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
      switch (AgentModel.lookupByName(ctx.agentRegistry, name)) {
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
      // User path: prefer an explicit ::agentname reference; fall back to first #_system(#admin).
      let validAgents = AgentRefParser.extractValidAgents(msg.text, ctx.agentRegistry);
      if (validAgents.size() > 0) {
        ?validAgents[0];
      } else {
        switch (AgentModel.getFirstByCategory(ctx.agentRegistry, #_system(#admin))) {
          case (null) {
            Logger.log(#warn, ?"MessageHandler", "No #_system(#admin) agent registered — cannot handle user message");
            null;
          };
          case (?agent) { ?agent };
        };
      };
    };
  };

  /// Derive the root timestamp for a message.
  /// Replies live inside a thread rooted at `threadTs`; standalone posts use their own `ts`.
  func rootTimestamp(msg : IncomingMsg) : Text {
    switch (msg.threadTs) {
      case (?ts) { ts };
      case (null) { msg.ts };
    };
  };

  /// Phase 1.4 — Fetch the existing channel history entry (for LLM context), then
  /// immediately persist the incoming message with a null auth context.
  ///
  /// The entry is fetched BEFORE the message is stored so the LLM context does
  /// not include the triggering message itself.
  func persistIncomingMessage(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
    rootTs : Text,
  ) : ?ChannelHistoryModel.TimelineEntry {
    let entry = ChannelHistoryModel.getEntry(ctx.channelHistory, msg.channel, rootTs);
    ChannelHistoryModel.addMessage(
      ctx.channelHistory,
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
    entry;
  };

  /// Post a termination prompt to Slack — best-effort, silently ignores a missing token.
  ///
  /// This message carries NO `AgentMessageMetadata` — it must not re-trigger
  /// round tracking when Slack echoes it back to our webhook.
  func postTerminationIfTokenAvailable(
    botTokenOpt : ?Text,
    channel : Text,
    threadTs : ?Text,
  ) : async () {
    let botToken = switch (botTokenOpt) {
      case (null) { return };
      case (?token) { token };
    };
    let text = "⚠️ I've reached the maximum number of steps for this session. Reply with **continue** (or **::agentname continue**) in this thread to allow me to keep going.";
    ignore await SlackWrapper.postMessage(botToken, channel, text, threadTs, null);
  };

  /// Post the agent reply to Slack and assemble the final HandlerResult.
  /// Returns the HandlerResult paired with a Bool indicating whether the Slack
  /// post succeeded, so the caller can mark the turn #failed when the user
  /// never received a reply.
  func postAgentReply(
    botToken : Text,
    msg : IncomingMsg,
    replyText : Text,
    primaryAgent : AgentModel.AgentRecord,
    llmSteps : [Types.ProcessingStep],
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
  ) : async (NormalizedEventTypes.HandlerResult, Bool) {
    let replyMetadata = buildReplyMetadata(msg.channel, msg.ts, primaryAgent, turnId);
    let slackResult = await SlackWrapper.postMessage(botToken, msg.channel, replyText, msg.threadTs, replyMetadata);
    let slackOk = switch (slackResult) {
      case (#ok(_)) { true };
      case (#err(_)) { false };
    };
    let slackStep : Types.ProcessingStep = {
      action = "post_to_slack";
      result = switch (slackResult) {
        case (#ok(_)) { #ok };
        case (#err(e)) { #err(e) };
      };
      timestamp = Time.now();
    };
    // Record the reply in the turn's trace.
    switch (slackResult) {
      case (#ok({ ts = replyTs; channel = _ })) {
        SessionModel.appendTrace(sessionStores, turnId, #slackPost({ channelId = msg.channel; threadTs = msg.threadTs; ts = replyTs }));
      };
      case (#err(_)) {};
    };
    (#ok(Array.concat(llmSteps, [slackStep])), slackOk);
  };

  // ─── Public entry point ──────────────────────────────────────────────────────

  public func handle(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {

    let workspaceId = resolveWorkspaceId(msg.channel, ctx.workspaces);
    let rootTs = rootTimestamp(msg);

    // Fetch the org key early to allow bot token fetching before round context check
    let orgKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, 0);

    // Fetch bot token early so it can be used in both early-exit and normal paths
    let botTokenRequester : SecretModel.SecretRequester = {
      slackUserId = null;
      agentId = null;
      operation = "message-handler:bot-token";
    };
    let botTokenOpt = SecretModel.resolvePlatformSecret(ctx.secrets, orgKey, null, #slackBotToken, botTokenRequester);

    // ── Phase 1.4 — Persist incoming message ─────────────────────────────────
    ignore persistIncomingMessage(msg, ctx, rootTs);

    // ── Phase 1.5 — Round tracking + pre-condition guards ────────────────────
    let roundResult = resolveRoundContext(msg, ctx);
    let (activeCtxOpt, triggerTurnId) : (?SlackAuthMiddleware.UserAuthContext, ?Text) = switch (roundResult) {
      case (#skip(result)) { return result };
      case (#skipWithTermination(result)) {
        // Post the termination prompt before returning (best-effort, await available here).
        await postTerminationIfTokenAvailable(botTokenOpt, msg.channel, msg.threadTs);
        return result;
      };
      case (#proceed({ authCtx; triggerTurnId })) { (authCtx, triggerTurnId) };
    };

    // Stamp the auth context on the persisted message.
    ignore ChannelHistoryModel.updateMessageContext(ctx.channelHistory, msg.channel, rootTs, msg.ts, activeCtxOpt);

    // ── Phase 1.6 — Resolve primary agent ────────────────────────────────────
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

    // ── Channel guard ─────────────────────────────────────────────────────────
    // Helper: post a user-visible error and return a two-step result.
    // Uses botTokenOpt (already fetched); silently skips the Slack post if no token.
    func guardReject(errMsg : Text, slackText : Text) : async NormalizedEventTypes.HandlerResult {
      let guardStep : Types.ProcessingStep = {
        action = "channel_guard";
        result = #err(errMsg);
        timestamp = Time.now();
      };
      let slackResult = switch (botTokenOpt) {
        case (null) { #err("no bot token") };
        case (?token) {
          switch (await SlackWrapper.postMessage(token, msg.channel, slackText, msg.threadTs, null)) {
            case (#ok(_)) { #ok };
            case (#err(e)) { #err(e) };
          };
        };
      };
      #ok([guardStep, { action = "post_to_slack"; result = slackResult; timestamp = Time.now() }]);
    };

    switch (primaryAgent.category) {
      case (#_system(#admin)) {
        let adminChannelId : ?Text = switch (WorkspaceModel.getWorkspace(ctx.workspaces, primaryAgent.ownedBy)) {
          case (?ws) { ws.adminChannelId };
          case (null) { null };
        };
        let allowedId = switch (adminChannelId) {
          case (null) {
            return await guardReject(
              "admin channel not yet configured",
              "The admin channel for this workspace has not yet been configured. Use set_workspace_admin_channel to anchor it.",
            );
          };
          case (?id) { id };
        };
        if (allowedId != msg.channel) {
          return await guardReject(
            "channel not admin channel",
            "Agent '" # primaryAgent.config.name # "' can only be invoked from the configured admin channel (" # allowedId # ").",
          );
        };
      };
      case (_) {
        if (not Set.contains(primaryAgent.config.allowedChannelIds, Text.compare, msg.channel)) {
          return await guardReject(
            "channel not in allowlist",
            "Agent '" # primaryAgent.config.name # "' is not allowed in this channel.",
          );
        };
      };
    };

    // ── Create turn ──────────────────────────────────────────────────────────
    let sourceRef : ?SessionModel.SourceRef = ?#slack({
      channelId = msg.channel;
      ts = msg.ts;
      threadTs = msg.threadTs;
    });
    let turn = SessionModel.createTurn(
      ctx.sessionStores,
      primaryAgent.id,
      sourceRef,
      triggerTurnId,
      activeCtxOpt,
    );
    let turnId = turn.turnId;

    // ── Orchestration (shared path for user and bot messages) ─────────────────

    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);

    let slackUserId : ?Text = switch (activeCtxOpt) {
      case (?c) { ?c.slackUserId };
      case (null) { null };
    };

    // Bot token was already fetched early; use it here
    let botToken = switch (botTokenOpt) {
      case (null) {
        SessionModel.completeTurn(ctx.sessionStores, turnId, #failed, null, ?"No Slack bot token configured");
        return #ok([{
          action = "post_to_slack";
          result = #err("No Slack bot token configured");
          timestamp = Time.now();
        }]);
      };
      case (?token) { token };
    };

    let routeResult = await AgentOrchestrator.orchestrate(
      primaryAgent,
      ctx.channelHistory,
      msg.channel,
      msg.threadTs,
      ?msg.text,
      turnId,
      ctx.sessionStores,
      activeCtxOpt,
      slackUserId,
      ctx.secrets,
      encryptionKey,
      orgKey,
      ctx.workspaces,
      { envelopeState = ctx.envelopeState; internalEngine = ctx.internalEngine },
    );

    switch (routeResult) {
      case (#dispatched({ steps })) {
        // Engine accepted the envelope — mark turn pending.
        // Response will arrive async via processExecutionAsyncEffect.
        SessionModel.markPending(ctx.sessionStores, turnId);
        #ok(steps);
      };
      case (#ok({ response; steps })) {
        // Synchronous response (future non-engine agents)
        let (result, slackOk) = await postAgentReply(botToken, msg, response, primaryAgent, steps, turnId, ctx.sessionStores);
        let cost = SessionModel.aggregateTurnCost(ctx.sessionStores, turnId);
        if (not slackOk) {
          SessionModel.completeTurn(ctx.sessionStores, turnId, #failed, cost, ?"Slack post failed");
        } else {
          SessionModel.completeTurn(ctx.sessionStores, turnId, #succeeded, cost, null);
        };
        result;
      };
      case (#err({ message; steps })) {
        // Dispatch failure — post error to Slack so user sees something
        let errorText = "[Agent error] " # message;
        let (result, _slackOk) = await postAgentReply(botToken, msg, errorText, primaryAgent, steps, turnId, ctx.sessionStores);
        let cost = SessionModel.aggregateTurnCost(ctx.sessionStores, turnId);
        SessionModel.completeTurn(ctx.sessionStores, turnId, #failed, cost, ?message);
        result;
      };
    };
  };
};
