/// Message Handler
/// Handles standard user messages, me_messages, and app_mentions.
///
/// Acts as a controller for the message event:
///   1. Scopes workspace data from EventProcessingContext
///   2. Derives the workspace encryption key (once)
///   3. Calls WorkspaceAdminOrchestrator for LLM reply
///   4. Posts the reply back to Slack via SlackWrapper

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import List "mo:core/List";
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
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageHandler",
      "message in workspace " # debug_show (workspaceId) #
      " | channel: " # msg.channel #
      " | user: " # msg.user #
      " | text: " # msg.text,
    );

    // --- 1. Scope workspace data ---
    let workspaceSecrets = Map.get(ctx.secrets, Nat.compare, workspaceId);
    let workspaceConversations = switch (Map.get(ctx.adminConversations, Nat.compare, workspaceId)) {
      case (?list) { list };
      case (null) {
        let newList = List.empty<ConversationModel.Message>();
        Map.add(ctx.adminConversations, Nat.compare, workspaceId, newList);
        newList;
      };
    };
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

    // --- 2. Derive encryption key once for this event ---
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(ctx.keyCache, workspaceId);

    // --- 3. Decrypt the Slack bot token ---
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

    // --- 4. Call the orchestrator with the scoped workspace data ---
    let orchestratorResult = await WorkspaceAdminOrchestrator.orchestrateAdminTalk(
      ctx.mcpToolRegistry,
      workspaceSecrets,
      workspaceConversations,
      workspaceValueStreamsState,
      ctx.workspaceValueStreams,
      workspaceObjectivesMap,
      ctx.metricsRegistry,
      ctx.metricDatapoints,
      workspaceId,
      msg.text,
      encryptionKey,
    );

    // --- 5. Extract the LLM steps and last assistant reply ---
    let (llmSteps, replyTextOpt) : ([Types.ProcessingStep], ?Text) = switch (orchestratorResult) {
      case (#err(e)) {
        ([{ action = "llm_call"; result = #err(e); timestamp = Time.now() }], null);
      };
      case (#ok({ messages; steps })) {
        var lastAssistant : ?Text = null;
        for (m in messages.vals()) {
          switch (m.author) {
            case (#agent) { lastAssistant := ?m.content };
            case (_) {};
          };
        };
        (steps, lastAssistant);
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

    // --- 6. Post reply to Slack ---
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
