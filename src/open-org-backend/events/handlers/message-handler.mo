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

  public func handle(
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
      isBotMessage : Bool;
      agentMetadata : ?Types.AgentMessageMetadata;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    // Resolve workspace from the channel — the handler owns this resolution, not the event payload.
    let workspaceId : Nat = switch (WorkspaceModel.resolveWorkspaceByChannel(ctx.workspaces, msg.channel)) {
      case (#adminChannel(wsId)) { wsId };
      case (#memberChannel(wsId)) { wsId };
      case (#none) { 0 }; // default workspace — channel not yet anchored
    };

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
    // Phase 1.5 — Round tracking + pre-condition guards
    // =========================================================
    //
    // `activeCtxOpt` carries the UserAuthContext for this message.
    // It is persisted on ConversationMessage in step 7 so the chain can
    // be reconstructed by future rounds via getMessage + agentMetadata.
    var activeCtxOpt : ?SlackAuthMiddleware.UserAuthContext = null;

    if (msg.isBotMessage) {
      // --- Bot message path ---
      // Adapter already enforces agentMetadata != null for own-bot messages;
      // guard defensively here.
      let agentMeta = switch (msg.agentMetadata) {
        case (null) {
          Logger.log(#warn, ?"MessageHandler", "Bot message missing agentMetadata — skipping");
          return #ok([{
            action = "round_skip";
            result = #err("bot message missing agentMetadata");
            timestamp = Time.now();
          }]);
        };
        case (?m) { m };
      };

      // Resolve the parent ConversationMessage via metadata lineage.
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
          return #ok([{
            action = "round_skip";
            result = #err("parent message not found in store");
            timestamp = Time.now();
          }]);
        };
        case (?m) { m };
      };

      // The parent message carries the auth context; null means unauthenticated at storage time.
      let parentCtx = switch (parentMsg.userAuthContext) {
        case (null) {
          Logger.log(
            #info,
            ?"MessageHandler",
            "Parent message has no userAuthContext — discarding bot message",
          );
          return #ok([{
            action = "round_skip";
            result = #err("parent message has no userAuthContext");
            timestamp = Time.now();
          }]);
        };
        case (?c) { c };
      };

      // Pre-condition 1: session was force-terminated.
      if (parentCtx.forceTerminated) {
        Logger.log(#info, ?"MessageHandler", "Session force-terminated — discarding bot message");
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

      // Derive the new round count (O(log N) parent lookup already done above).
      let newRound = parentCtx.roundCount + 1;

      // canonical parentRef for the new context — points back to the triggering message.
      let newParentRef : ?{ channelId : Text; ts : Text } = ?{
        channelId = agentMeta.event_payload.parent_channel;
        ts = agentMeta.event_payload.parent_ts;
      };

      // Hard ceiling: MAX_AGENT_ROUNDS reached → force-terminate, store, and stop.
      if (newRound >= Constants.MAX_AGENT_ROUNDS) {
        let terminatedCtx = SlackAuthMiddleware.withRound(parentCtx, newRound, true, newParentRef);
        // Store the incoming message with the terminated context so the chain is complete.
        ConversationModel.addMessage(
          ctx.conversationStore,
          msg.channel,
          { ts = msg.ts; userAuthContext = ?terminatedCtx; text = msg.text },
          msg.threadTs,
        );
        Logger.log(
          #warn,
          ?"MessageHandler",
          "MAX_AGENT_ROUNDS (" # Nat.toText(Constants.MAX_AGENT_ROUNDS) # ") reached — force-terminating session",
        );
        // Phase 1.6 will post a continuation prompt to Slack here.
        return #ok([{
          action = "round_force_terminated";
          result = #err("max agent rounds reached");
          timestamp = Time.now();
        }]);
      };

      // Advance the round context.
      let activeCtx = SlackAuthMiddleware.withRound(parentCtx, newRound, false, newParentRef);
      activeCtxOpt := ?activeCtx;

      Logger.log(
        #info,
        ?"MessageHandler",
        "Bot message round " # Nat.toText(newRound) #
        " | parent: " # agentMeta.event_payload.parent_ts #
        " | user: " # activeCtx.slackUserId #
        " | agent(s): " # debug_show (Array.map<AgentModel.AgentRecord, Text>(validAgents, func(a) { a.name })),
      );

      // Fall through to orchestration.
      // Phase 1.6 (Agent Router) will replace this with category-aware routing
      // to the specific agent referenced in `validAgents`.

    } else {
      // --- User message path ---
      // Build a fresh UserAuthContext (roundCount = 0, parentRef = null).
      // Persisted on the ConversationMessage in step 7.
      switch (SlackAuthMiddleware.buildFromCache(msg.user, ctx.slackUsers.cache)) {
        case (null) {
          // User is not in the Slack user cache yet (e.g. cache not yet populated).
          // Log and proceed — message will be stored without auth context.
          Logger.log(
            #warn,
            ?"MessageHandler",
            "Slack user " # msg.user # " not found in cache — no userAuthContext for message " # msg.ts,
          );
        };
        case (?userCtx) {
          activeCtxOpt := ?userCtx;
          Logger.log(
            #info,
            ?"MessageHandler",
            "UserAuthContext built for " # msg.user # " | message: " # msg.ts,
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
      case (#err({ message = _; steps })) {
        (steps, null);
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

    // --- 7. Persist messages to conversation store ---
    // Store the incoming message with its derived auth context on successful LLM response.
    // - User message (isBotMessage=false): userAuthContext = fresh ctx, roundCount = 0.
    // - Own-bot event (isBotMessage=true):  userAuthContext = derived ctx, roundCount = parent+1.
    // `activeCtxOpt` was set in the round-tracking section above.
    ConversationModel.addMessage(
      ctx.conversationStore,
      msg.channel,
      { ts = msg.ts; userAuthContext = activeCtxOpt; text = msg.text },
      msg.threadTs,
    );
    // Store the agent response (bot reply the handler is about to post to Slack).
    // Stored with null userAuthContext — role = #assistant for LLM context building.
    // Synthetic reply ts keeps ordering stable before the real Slack-assigned ts is known.
    let replyTs = msg.ts # "r"; // synthetic ts: original ts + "r" suffix
    ConversationModel.addMessage(
      ctx.conversationStore,
      msg.channel,
      { ts = replyTs; userAuthContext = null; text = replyText },
      ?rootTs, // always a thread reply to maintain the group structure
    );

    // --- 8. Post reply to Slack ---
    // Always embed agentMetadata so the round chain is self-describing.
    // parent_agent: the ::agentname referenced in the triggering message (or "::admin" fallback).
    // parent_ts / parent_channel: identify the message that triggered this reply.
    let msgValidAgents = AgentRefParser.extractValidAgents(msg.text, ctx.agentRegistry);
    let parentAgentName : Text = if (msgValidAgents.size() > 0) {
      "::" # msgValidAgents[0].name;
    } else {
      "::admin" // fallback during Phase 1.5 — Phase 1.6 Agent Router will use the actual agent
    };
    let replyMetadata : ?Types.AgentMessageMetadata = ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = parentAgentName;
        parent_ts = msg.ts;
        parent_channel = msg.channel;
      };
    };
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
