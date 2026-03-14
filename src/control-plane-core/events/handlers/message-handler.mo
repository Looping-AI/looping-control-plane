/// Message Handler
/// Handles standard user messages, me_messages, and own-bot agent messages.
///
/// The public `handle` function is a thin orchestration sequence that delegates
/// each discrete responsibility to a private helper:
///
///   Phase 1.4  persistIncomingMessage  — fetch LLM context entry, then store the
///                                        incoming message with a null auth context.
///   Phase 1.5  resolveRoundContext     — enforce round guards and advance the
///                                        UserAuthContext lineage (user or bot path).
///              postTerminationIfTokenAvailable — post the ceiling prompt when
///                                        the session must be force-terminated.
///   Phase 1.6  resolvePrimaryAgent     — pick the agent to route to.
///              dispatchToAgentRouter   — call AgentRouter.route and unpack the result.
///              postAgentReply          — post the reply to Slack and emit the final
///                                        HandlerResult.
///
/// Helper inventory (sync):
///   resolveWorkspaceId, rootTimestamp, persistIncomingMessage,
///   resolveRoundContext → resolveBotRoundContext / resolveUserRoundContext,
///   scopeWorkspaceData, buildReplyMetadata, resolvePrimaryAgent,
///   resolveWorkspaceBotToken
///
/// Helper inventory (async):
///   postTerminationIfTokenAvailable, dispatchToAgentRouter,
///   postAgentReply
///
/// Note: the bot reply is NOT explicitly stored here — Slack echoes the posted
/// message back as a bot event, which is stored via the normal incoming-message
/// path (persistIncomingMessage), ensuring exactly one write per reply.

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
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState;
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap;
  } {
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
    { workspaceValueStreamsState; workspaceObjectivesMap };
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
  ) : ?Types.AgentMessageMetadata {
    ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = primaryAgent.name;
        parent_ts = ts;
        parent_channel = channel;
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

  /// Derive the root timestamp for a message.
  /// Replies live inside a thread rooted at `threadTs`; standalone posts use their own `ts`.
  func rootTimestamp(msg : IncomingMsg) : Text {
    switch (msg.threadTs) {
      case (?ts) { ts };
      case (null) { msg.ts };
    };
  };

  /// Phase 1.4 — Fetch the existing conversation entry (for LLM context), then
  /// immediately persist the incoming message with a null auth context.
  ///
  /// The entry is fetched BEFORE the message is stored so the LLM context does
  /// not include the triggering message itself.
  func persistIncomingMessage(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
    rootTs : Text,
  ) : ?ConversationModel.TimelineEntry {
    let entry = ConversationModel.getEntry(ctx.conversationStore, msg.channel, rootTs);
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
    entry;
  };

  /// Resolve the Slack bot token for the given workspace.
  /// Returns null (and logs a warning) when no token secret is configured.
  func resolveWorkspaceBotToken(
    secrets : SecretModel.SecretsState,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    requester : SecretModel.SecretRequester,
  ) : ?Text {
    switch (SecretModel.getSecret(secrets, encryptionKey, workspaceId, #slackBotToken, requester)) {
      case (null) {
        Logger.log(
          #warn,
          ?"MessageHandler",
          "No Slack bot token found for workspace " # debug_show (workspaceId),
        );
        null;
      };
      case (?token) { ?token };
    };
  };

  /// Post a termination prompt to Slack, deriving the bot token from scratch.
  ///
  /// Used when the MAX_AGENT_ROUNDS ceiling (#skipWithTermination) is reached.
  /// Best-effort — silently ignores missing tokens.
  func postTerminationIfTokenAvailable(
    ctx : EventProcessingContextTypes.EventProcessingContext,
    workspaceId : Nat,
    channel : Text,
    threadTs : ?Text,
  ) : async () {
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);
    let requester : SecretModel.SecretRequester = {
      slackUserId = null;
      agentId = null;
      operation = "message-handler:termination-token";
    };
    switch (resolveWorkspaceBotToken(ctx.secrets, encryptionKey, workspaceId, requester)) {
      case (?tok) {
        await AgentRouter.postTerminationPrompt(tok, channel, threadTs);
      };
      case (null) {};
    };
  };

  /// Dispatch to AgentRouter and unpack the result into (llmSteps, ?replyText).
  /// Returns null reply text when the orchestrator signals an error.
  func dispatchToAgentRouter(
    primaryAgent : AgentModel.AgentRecord,
    ctx : EventProcessingContextTypes.EventProcessingContext,
    slackUserId : ?Text,
    conversationEntry : ?ConversationModel.TimelineEntry,
    agentCtx : AgentRouter.AgentCtx,
    msgText : Text,
    encryptionKey : [Nat8],
  ) : async ([Types.ProcessingStep], ?Text) {
    let result = await AgentRouter.route(
      primaryAgent,
      ctx.mcpToolRegistry,
      ctx.secrets,
      slackUserId,
      conversationEntry,
      agentCtx,
      msgText,
      encryptionKey,
    );
    switch (result) {
      case (#err({ message = _; steps })) { (steps, null) };
      case (#ok({ response; steps })) { (steps, ?response) };
    };
  };

  /// Post the agent reply to Slack and assemble the final HandlerResult.
  func postAgentReply(
    botToken : Text,
    msg : IncomingMsg,
    replyText : Text,
    primaryAgent : AgentModel.AgentRecord,
    llmSteps : [Types.ProcessingStep],
  ) : async NormalizedEventTypes.HandlerResult {
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

  // ─── Public entry point ──────────────────────────────────────────────────────

  public func handle(
    msg : IncomingMsg,
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {

    let workspaceId = resolveWorkspaceId(msg.channel, ctx.workspaces);
    let rootTs = rootTimestamp(msg);

    // ── Phase 1.4 — Persist incoming message ─────────────────────────────────
    let conversationEntry = persistIncomingMessage(msg, ctx, rootTs);

    // ── Phase 1.5 — Round tracking + pre-condition guards ────────────────────
    let activeCtxOpt : ?SlackAuthMiddleware.UserAuthContext = switch (resolveRoundContext(msg, ctx)) {
      case (#skip(result)) { return result };
      case (#skipWithTermination(result)) {
        // Post the termination prompt before returning (best-effort, await available here).
        await postTerminationIfTokenAvailable(ctx, workspaceId, msg.channel, msg.threadTs);
        return result;
      };
      case (#proceed(ctxOpt)) { ctxOpt };
    };

    // Stamp the incremented auth context on the persisted message.
    ignore ConversationModel.updateMessageContext(ctx.conversationStore, msg.channel, rootTs, msg.ts, activeCtxOpt);

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

    // ── Orchestration (shared path for user and bot messages) ─────────────────

    let { workspaceValueStreamsState; workspaceObjectivesMap } = scopeWorkspaceData(ctx, workspaceId);
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);

    let slackUserId : ?Text = switch (activeCtxOpt) {
      case (?c) { ?c.slackUserId };
      case (null) { null };
    };
    let botTokenRequester : SecretModel.SecretRequester = {
      slackUserId;
      agentId = ?primaryAgent.id;
      operation = "message-handler:bot-token";
    };
    let botToken = switch (resolveWorkspaceBotToken(ctx.secrets, encryptionKey, workspaceId, botTokenRequester)) {
      case (null) {
        return #ok([{
          action = "post_to_slack";
          result = #err("No Slack bot token configured for workspace");
          timestamp = Time.now();
        }]);
      };
      case (?token) { token };
    };

    // Build the per-category context variant — passes only the data each agent needs.
    let agentCtx : AgentRouter.AgentCtx = switch (primaryAgent.category) {
      case (#admin) {
        #admin({
          workspaces = ctx.workspaces;
          agentRegistry = ctx.agentRegistry;
          slackBotToken = ?botToken;
          userAuthContext = activeCtxOpt;
          secrets = ctx.secrets;
          keyCache = ctx.keyCache;
          eventStore = ctx.eventStore;
        });
      };
      case (#planning) {
        #planning({
          workspaceValueStreamsState;
          valueStreamsMap = ctx.workspaceValueStreams;
          workspaceObjectivesMap;
          metricsRegistryState = ctx.metricsRegistry;
          metricDatapoints = ctx.metricDatapoints;
          workspaceId;
        });
      };
      case (#research) { #research };
      case (#communication) { #communication };
    };

    let (llmSteps, replyTextOpt) = await dispatchToAgentRouter(
      primaryAgent,
      ctx,
      slackUserId,
      conversationEntry,
      agentCtx,
      msg.text,
      encryptionKey,
    );

    let replyText = switch (replyTextOpt) {
      case (null) {
        Logger.log(#warn, ?"MessageHandler", "No assistant reply generated for workspace " # debug_show (workspaceId));
        return #ok(llmSteps);
      };
      case (?text) { text };
    };

    // ── Post reply to Slack ───────────────────────────────────────────────────
    await postAgentReply(botToken, msg, replyText, primaryAgent, llmSteps);
  };
};
