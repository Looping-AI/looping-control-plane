/// Agent Router
///
/// Sits between MessageHandler and the agent services.  Its sole
/// responsibility is: given a resolved `primaryAgent` and all the data
/// required for execution, dispatch to the correct category service.
///
/// Additional responsibilities introduced in Phase 1.6:
///   - Termination-prompt delivery (MAX_AGENT_ROUNDS)
///   - `findPreviousSameAgentReply` for walking the parentRef chain

import Text "mo:core/Text";
import Time "mo:core/Time";
import ConversationModel "../models/conversation-model";
import AgentModel "../models/agent-model";
import Types "../types";
import AgentOrchestrator "../orchestrators/agent-orchestrator";
import SlackWrapper "../wrappers/slack-wrapper";
import SecretModel "../models/secret-model";
import McpToolRegistry "../tools/mcp-tool-registry";
import Logger "../utilities/logger";

module {

  // ─── Context type aliases ─────────────────────────────────────────────────────
  //
  // Defined in AgentOrchestrator; re-exported here so callers only need one import.

  /// Context for the org-admin agent (workspace lifecycle + channel anchors).
  public type AdminAgentCtx = AgentOrchestrator.AdminAgentCtx;

  /// Context for the work-planning agent (value streams, metrics, objectives).
  public type PlanningAgentCtx = AgentOrchestrator.PlanningAgentCtx;

  /// Per-category context union — callers construct the right variant based on
  /// `primaryAgent.category` and pass it to `route()`.
  public type AgentCtx = AgentOrchestrator.AgentCtx;

  // ─── Result type ─────────────────────────────────────────────────────────────

  /// Shared result type returned by `route()`.
  public type RouteResult = {
    #ok : { response : Text; steps : [Types.ProcessingStep] };
    #err : { message : Text; steps : [Types.ProcessingStep] };
  };

  // ─── Dispatch ────────────────────────────────────────────────────────────────

  /// Validate the `(agent.category, agentCtx)` pairing and dispatch to the
  /// orchestrator.
  ///
  /// Returns `#err` if the category tag in `agentCtx` does not match
  /// `primaryAgent.category` — this is an internal invariant violation and
  /// should never happen in production; the error message is intentionally
  /// descriptive for easier debugging.
  public func route(
    primaryAgent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    secrets : SecretModel.SecretsState,
    slackUserId : ?Text,
    conversationEntry : ?ConversationModel.TimelineEntry,
    agentCtx : AgentCtx,
    message : Text,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
  ) : async RouteResult {
    // Validate that the ctx variant matches the agent's declared category.
    let ctxMatchesCategory : Bool = switch (primaryAgent.category, agentCtx) {
      case (#admin, #admin(_)) { true };
      case (#planning, #planning(_)) { true };
      case (#research, #research) { true };
      case (#communication, #communication) { true };
      case _ { false };
    };

    if (not ctxMatchesCategory) {
      let step : Types.ProcessingStep = {
        action = "route";
        result = #err("agent context mismatch");
        timestamp = Time.now();
      };
      return #err({
        message = "agent context mismatch: category=" # debug_show (primaryAgent.category) # " does not match the provided agentCtx variant";
        steps = [step];
      });
    };

    // Branch on execution type before dispatching to the category orchestrator.
    // #api agents run in-canister. #runtime agents are not yet supported.
    switch (primaryAgent.executionType) {
      case (#runtime(_)) {
        let step : Types.ProcessingStep = {
          action = "route";
          result = #err("remote runtime not yet supported");
          timestamp = Time.now();
        };
        return #err({
          message = "Agent uses a remote runtime that is not yet supported in this version.";
          steps = [step];
        });
      };
      case (#api) {};
    };

    // Forward to the orchestrator with the typed context
    await AgentOrchestrator.orchestrateAgentTalk(
      primaryAgent,
      mcpToolRegistry,
      secrets,
      slackUserId,
      conversationEntry,
      agentCtx,
      message,
      workspaceKey,
      orgKey,
    );
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
