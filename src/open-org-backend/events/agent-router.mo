/// Agent Router
///
/// Sits between MessageHandler and the agent services.  Its sole
/// responsibility is: given a resolved `primaryAgent` and all the data
/// required for execution, dispatch to the correct category service.
///
/// Additional responsibilities introduced in Phase 1.6:
///   - Termination-prompt delivery (MAX_AGENT_ROUNDS)
///   - `findPreviousSameAgentReply` for walking the parentRef chain

import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import ConversationModel "../models/conversation-model";
import AgentModel "../models/agent-model";
import Types "../types";
import WorkspaceAdminOrchestrator "../orchestrators/workspace-admin-orchestrator";
import SlackWrapper "../wrappers/slack-wrapper";
import SecretModel "../models/secret-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import McpToolRegistry "../tools/mcp-tool-registry";
import Logger "../utilities/logger";

module {

  // ─── Types ───────────────────────────────────────────────────────────────────

  /// Shared result type for all category dispatches.
  public type RouteResult = {
    #ok : { response : Text; steps : [Types.ProcessingStep] };
    #err : { message : Text; steps : [Types.ProcessingStep] };
  };

  // ─── Dispatch ────────────────────────────────────────────────────────────────

  /// Dispatch to the appropriate agent service based on `primaryAgent.category`.
  ///
  /// Currently only `#admin` is wired to an implementation; `#research` and
  /// `#communication` return a stub error until Phase 1.7 introduces the generic
  /// agent service.
  public func route(
    primaryAgent : AgentModel.AgentRecord,
    agentRegistry : AgentModel.AgentRegistryState,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    workspaceSecrets : ?Map.Map<Types.SecretId, SecretModel.EncryptedSecret>,
    conversationEntry : ?ConversationModel.TimelineEntry,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    encryptionKey : [Nat8],
  ) : async RouteResult {
    switch (primaryAgent.category) {
      case (#admin) {
        await WorkspaceAdminOrchestrator.orchestrateAdminTalk(
          agentRegistry,
          mcpToolRegistry,
          workspaceSecrets,
          conversationEntry,
          workspaceValueStreamsState,
          valueStreamsMap,
          workspaceObjectivesMap,
          metricsRegistryState,
          metricDatapoints,
          workspaceId,
          message,
          encryptionKey,
        );
      };
      case (#research) {
        let step : Types.ProcessingStep = {
          action = "route";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
      case (#communication) {
        let step : Types.ProcessingStep = {
          action = "route";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
    };
  };

  // ─── Termination prompt ──────────────────────────────────────────────────────

  /// Post a user-visible Slack message informing the user that the maximum number
  /// of session rounds has been reached, and prompting them to reply "continue"
  /// if they want more.
  ///
  /// This message carries NO `AgentMessageMetadata` — it must not re-trigger
  /// round tracking when Slack echoes it back to our webhook.
  public func postTerminationPrompt(
    botToken : Text,
    channel : Text,
    threadTs : ?Text,
  ) : async () {
    let text = "⚠️ I've reached the maximum number of steps for this session. Reply with **continue** (or **::agentname continue**) in this thread to allow me to keep going.";
    ignore await SlackWrapper.postMessage(botToken, channel, text, threadTs, null);
  };

  // ─── Chain walk ──────────────────────────────────────────────────────────────

  /// Walk the `parentRef` chain backwards from `startTs` in `channel`, looking
  /// for the first `ConversationMessage` whose `agentMetadata.parent_agent == agentName`.
  ///
  /// The walk terminates when:
  ///   - The message is found → return `?msg`.
  ///   - A message has no `userAuthContext` or `parentRef == null` → return `null`
  ///     (chain end, no prior reply from this agent).
  ///   - A message is not found in the store → return `null` (pruned or never stored).
  ///
  /// Exported for unit testability.
  public func findPreviousSameAgentReply(
    store : ConversationModel.ConversationStore,
    channel : Text,
    startTs : Text,
    agentName : Text, // bare name, no "::" prefix
  ) : ?ConversationModel.ConversationMessage {
    let targetAuthor : ?Text = ?agentName;
    var currentChannel = channel;
    var currentTs = startTs;
    loop {
      switch (ConversationModel.getMessage(store, currentChannel, currentTs)) {
        case (null) {
          // Message not found — pruned or never stored.
          Logger.log(
            #info,
            ?"AgentRouter",
            "findPreviousSameAgentReply: message not found channel=" # currentChannel # " ts=" # currentTs,
          );
          return null;
        };
        case (?msg) {
          // Check if this message was authored by the target agent.
          // `agentMetadata.parent_agent` holds the bare agent name for bot replies;
          // null agentMetadata means this is a user message, never a match.
          let msgAuthor : ?Text = switch (msg.agentMetadata) {
            case (?meta) { ?meta.parent_agent };
            case (null) { null };
          };
          if (msgAuthor == targetAuthor) {
            return ?msg;
          };
          // Follow the parentRef chain.
          switch (msg.userAuthContext) {
            case (null) {
              // No auth context — chain is unresolvable.
              return null;
            };
            case (?ctx) {
              switch (ctx.parentRef) {
                case (null) {
                  // Round-0 message (original user message) — chain terminates.
                  return null;
                };
                case (?ref) {
                  currentChannel := ref.channelId;
                  currentTs := ref.ts;
                  // Continue loop.
                };
              };
            };
          };
        };
      };
    };
  };
};
