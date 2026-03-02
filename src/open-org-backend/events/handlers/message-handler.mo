/// Message Handler
/// Handles standard user messages, me_messages, and own-bot threaded messages.
///
/// Acts as a controller for the message event:
///   1. Round tracking (Phase 1.3):
///      - User message  → build a fresh UserAuthContext and store it for the thread.
///      - Bot message   → inherit the thread's stored UserAuthContext, apply
///                         pre-condition guards, then increment roundCount.
///   2. Persist the incoming message to the conversation store (Phase 1.4).
///   3. Scope workspace data from EventProcessingContext.
///   4. Derive the workspace encryption key (once).
///   5. Call WorkspaceAdminOrchestrator for LLM reply.
///   6. Persist the agent’s response to the conversation store (Phase 1.4).
///   7. Post the reply back to Slack via SlackWrapper.

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

module {

  public func handle(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageHandler",
      "message in workspace " # debug_show (workspaceId) #
      " | isBotMessage: " # debug_show (msg.isBotMessage) #
      " | channel: " # msg.channel #
      " | user: " # msg.user #
      " | text: " # msg.text,
    );

    // =========================================================
    // Phase 1.3 — Round tracking + pre-condition guards
    // =========================================================

    if (msg.isBotMessage) {
      // --- Bot message path ---
      // The Slack adapter guarantees threadTs is set for bot messages that
      // pass through.  Guard defensively anyway.
      let threadTs = switch (msg.threadTs) {
        case (null) {
          Logger.log(#warn, ?"MessageHandler", "Bot message with no threadTs — skipping");
          return #ok([{
            action = "round_skip";
            result = #err("bot message has no threadTs");
            timestamp = Time.now();
          }]);
        };
        case (?ts) { ts };
      };

      // Look up the parent session.
      let parentCtx = switch (ConversationModel.lookupRoundContext(ctx.conversationStore, msg.channel, threadTs)) {
        case (null) {
          Logger.log(#info, ?"MessageHandler", "No parent session for thread " # threadTs # " — skipping bot message");
          return #ok([{
            action = "round_skip";
            result = #err("no parent session for thread");
            timestamp = Time.now();
          }]);
        };
        case (?c) { c };
      };

      // Pre-condition 1: session was force-terminated.
      if (parentCtx.forceTerminated) {
        Logger.log(#info, ?"MessageHandler", "Session force-terminated for thread " # threadTs # " — discarding event");
        return #ok([{
          action = "round_skip";
          result = #err("session force-terminated");
          timestamp = Time.now();
        }]);
      };

      // Pre-condition 2: message must contain at least one valid ::agentname reference.
      let validAgents = AgentRefParser.extractValidAgents(msg.text, ctx.agentRegistry);
      if (validAgents.size() == 0) {
        Logger.log(#info, ?"MessageHandler", "No valid ::agentname reference in bot message — discarding event");
        return #ok([{
          action = "round_skip";
          result = #err("no valid agent reference");
          timestamp = Time.now();
        }]);
      };

      // Increment round count.
      let newRoundCount = parentCtx.roundCount + 1;

      // Hard ceiling: MAX_AGENT_ROUNDS reached → force-terminate and stop.
      if (newRoundCount >= Constants.MAX_AGENT_ROUNDS) {
        let terminatedCtx = SlackAuthMiddleware.withRound(parentCtx, newRoundCount, true);
        ConversationModel.saveRoundContext(ctx.conversationStore, msg.channel, threadTs, terminatedCtx);
        Logger.log(
          #warn,
          ?"MessageHandler",
          "MAX_AGENT_ROUNDS (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ") reached for thread " # threadTs # " — force-terminating session",
        );
        // Phase 1.4 will post an approval prompt to Slack here.
        return #ok([{
          action = "round_force_terminated";
          result = #err("max agent rounds reached");
          timestamp = Time.now();
        }]);
      };

      // Advance the round context with the incremented count.
      let activeCtx = SlackAuthMiddleware.withRound(parentCtx, newRoundCount, false);
      ConversationModel.saveRoundContext(ctx.conversationStore, msg.channel, threadTs, activeCtx);

      Logger.log(
        #info,
        ?"MessageHandler",
        "Bot message round " # Nat.toText(newRoundCount) # " for thread " # threadTs #
        " | user: " # activeCtx.slackUserId #
        " | agent(s): " # debug_show (Array.map<AgentModel.AgentRecord, Text>(validAgents, func(a) { a.name })),
      );

      // Fall through to orchestration.
      // Phase 1.4 (Agent Router) will replace this with category-aware routing
      // to the specific agent referenced in `validAgents`.

    } else {
      // --- User message path ---
      // Build (or refresh) a UserAuthContext for this user and store it so
      // subsequent bot messages in the same thread can inherit it.
      let threadKey = switch (msg.threadTs) {
        case (?ts) { ts }; // already inside a thread — key by thread root
        case (null) { msg.ts }; // top-level message — key by own ts
      };

      switch (SlackAuthMiddleware.buildFromCache(msg.user, ctx.slackUsers.cache)) {
        case (null) {
          // User is not in the Slack user cache yet (e.g. cache hasn't been
          // populated).  Log, but still proceed with message processing.
          Logger.log(
            #warn,
            ?"MessageHandler",
            "Slack user " # msg.user # " not found in cache — roundContext not seeded for thread " # threadKey,
          );
        };
        case (?userCtx) {
          // Seed the round context for this thread (roundCount = 0, not terminated).
          ConversationModel.saveRoundContext(ctx.conversationStore, msg.channel, threadKey, userCtx);
          Logger.log(
            #info,
            ?"MessageHandler",
            "Round context seeded for thread " # threadKey # " | user: " # msg.user,
          );
        };
      };
    };

    // =========================================================
    // Orchestration (shared path for user and bot messages)
    // =========================================================

    // --- 1. Scope workspace data ---
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

    // --- 2. Resolve conversation context (Phase 1.4) ---
    // rootTs is the thread root ts; equals msg.ts for top-level messages.
    let rootTs = switch (msg.threadTs) {
      case (?ts) { ts };
      case (null) { msg.ts };
    };
    // Fetch existing timeline entry for LLM context.
    // We fetch BEFORE storing the incoming message so the service doesn't see it twice.
    let conversationEntry = ConversationModel.getEntry(ctx.conversationStore, msg.channel, rootTs);

    // --- 3. Derive encryption key once for this event ---
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);

    // --- 4. Decrypt the Slack bot token ---
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

    // --- 5. Call the orchestrator with conversation context ---
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

    // --- 6. Extract the LLM steps and reply text ---
    let (llmSteps, replyTextOpt) : ([Types.ProcessingStep], ?Text) = switch (orchestratorResult) {
      case (#err(e)) {
        ([{ action = "llm_call"; result = #err(e); timestamp = Time.now() }], null);
      };
      case (#ok({ response; steps })) {
        (steps, ?response);
      };
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

    // --- 7. Persist messages to conversation store (Phase 1.4) ---
    // Store the incoming message (user or bot) only on successful LLM response.
    if (not msg.isBotMessage) {
      // User message: derive userAuthContext for role mapping
      let userCtxOpt = SlackAuthMiddleware.buildFromCache(msg.user, ctx.slackUsers.cache);
      ConversationModel.addMessage(
        ctx.conversationStore,
        msg.channel,
        { ts = msg.ts; userAuthContext = userCtxOpt; text = msg.text },
        msg.threadTs,
      );
    };
    // Store the agent response (bot message, always null userAuthContext)
    // Use a synthetic reply ts derived from the event ts to maintain ordering.
    let replyTs = msg.ts # "r"; // synthetic ts: original ts + "r" suffix
    ConversationModel.addMessage(
      ctx.conversationStore,
      msg.channel,
      { ts = replyTs; userAuthContext = null; text = replyText },
      ?rootTs, // always a thread reply to maintain the group structure
    );

    // --- 8. Post reply to Slack ---
    // If the message is already inside a thread, reply within that thread.
    // If it is a top-level channel message, post the reply as a new top-level
    // channel message — do NOT open a thread from a non-threaded message.
    let slackResult = await SlackWrapper.postMessage(botToken, msg.channel, replyText, msg.threadTs);
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
