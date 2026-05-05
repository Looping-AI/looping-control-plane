/// Block Actions Handler
///
/// Handles Slack Block Kit interactive component payloads dispatched by main.mo.
/// Processing runs entirely inside a zero-delay timer so main.mo can return HTTP 200
/// to Slack immediately — well within the 3-second interactive-payload response window.
///
/// Outcome messages are delivered asynchronously by POSTing to the Slack `response_url`
/// included in every Block Kit interactive payload. The response_url is self-authenticated
/// (no bot token required) and remains valid for 30 minutes.
///
/// Currently handles two action IDs on the approval Block Kit message:
///
///   approve_workflow  — marks the approval code #used, cancels the TTL timer, and
///                       fires-and-forgets AgentRunner.resumeWithApproval. Replaces the
///                       button message with "✅ Approved by <@userId>.".
///
///   deny_workflow     — marks the approval code #expired, cancels the TTL timer, and
///                       fires-and-forgets AgentRunner.resumeWithDenial("user denied").
///                       Replaces the button message with "🚫 Denied by <@userId>.".
///
/// Authorization (either condition must hold):
///   - The clicking user is the original requester (requestedByUserId).
///   - The clicking user is a workspace admin of the agent's owning workspace.
///
/// Timer interactions:
///   TTL timer cancellation happens synchronously before any await, so the TTL timer
///   cannot fire concurrently between the cancel and the resume dispatch.
///
/// <system> capability:
///   handle carries <system> so it can call Timer.setTimer<system> for fire-and-forget
///   async work. The caller (the timer closure in main.mo) provides <system> implicitly.

import Json "mo:json";
import { str; obj; bool } "mo:json";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Nat "mo:core/Nat";
import Timer "mo:core/Timer";
import SlackEventTypes "../types/slack-event-types";
import ApprovalModel "../../models/approval-model";
import SessionModel "../../models/session-model";
import AgentModel "../../models/agent-model";
import SlackUserModel "../../models/slack-user-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import AgentRunner "../../agents/agent-runner";
import KeyDerivationService "../../services/key-derivation-service";
import SecretModel "../../models/secret-model";
import ApprovalTimer "../../timers/approval-timer";
import Logger "../../utilities/logger";
import SlackWrapper "../../wrappers/slack-wrapper";

module {

  // ─── Types ────────────────────────────────────────────────────────────────

  public type BlockActionsDeps = {
    approvalState : ApprovalModel.ApprovalState;
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    slackUsers : SlackUserModel.SlackUserState;
    resumeDeps : AgentRunner.ResumeDeps;
    keyCache : KeyDerivationService.KeyCache;
  };

  // ─── Response helpers ─────────────────────────────────────────────────────

  /// Build a Slack replace_original JSON payload (sent via response_url).
  private func replaceOriginalBody(text : Text) : Text {
    Json.stringify(obj([("replace_original", bool(true)), ("text", str(text))]), null);
  };

  /// Build a Slack ephemeral response body (visible only to the clicking user).
  private func ephemeralBody(text : Text) : Text {
    Json.stringify(obj([("response_type", str("ephemeral")), ("text", str(text))]), null);
  };

  // ─── response_url posting ─────────────────────────────────────────────────

  /// Post `body` to `responseUrl`; log but do not propagate errors.
  private func postOutcome(responseUrl : Text, body : Text) : async () {
    if (responseUrl == "") {
      // No response_url (e.g. test environment or non-button surface) — skip silently.
      return;
    };
    switch (await SlackWrapper.postToResponseUrl(responseUrl, body)) {
      case (#ok) {};
      case (#err(e)) {
        Logger.log(#error, ?"BlockActions", "response_url POST failed: " # e);
      };
    };
  };

  // ─── Timer cancellation ───────────────────────────────────────────────────

  /// Cancel the TTL timer stored in the #awaitingApproval turn status, if any.
  /// This is synchronous and must run before any await.
  private func cancelTurnTimer(deps : BlockActionsDeps, turnId : Text) {
    switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
      case (null) {};
      case (?turn) {
        switch (turn.status) {
          case (#awaitingApproval(data)) {
            switch (data.timerId) {
              case (?tId) {
                ApprovalTimer.cancel(tId);
                data.timerId := null;
              };
              case null {};
            };
          };
          case _ {};
        };
      };
    };
  };

  // ─── Public entry point ───────────────────────────────────────────────────

  /// Process a Slack Block Kit interactive payload.
  ///
  /// Called from a zero-delay timer in main.mo — NOT from the HTTP handler — so
  /// there is no 3-second response-window pressure. All errors are logged; the
  /// button message is updated via response_url regardless of outcome.
  ///
  /// The <system> capability is required for Timer.setTimer used to fire-and-forget
  /// the async resume operations.
  public func handle<system>(
    payload : SlackEventTypes.BlockActionsPayload,
    deps : BlockActionsDeps,
  ) : async () {
    // Only handle the two approval action IDs.
    if (payload.actionId != "approve_workflow" and payload.actionId != "deny_workflow") {
      return;
    };

    // Build the caller's admin workspace set once — passed to the model so it can
    // verify authorization (requester OR workspace admin) without trusting a bool.
    let adminWorkspaces : Set.Set<Nat> = switch (SlackAuthMiddleware.buildFromCache(payload.userId, deps.slackUsers.cache)) {
      case (null) { Set.empty() };
      case (?authCtx) { authCtx.adminWorkspaces };
    };

    // Resolve the Slack bot token once before branching so both approve and deny
    // paths can forward it to the resume functions for error reporting.
    let botTokenOpt : ?Text = switch (Map.get(deps.keyCache, Nat.compare, 0)) {
      case (null) { null };
      case (?orgKey) {
        SecretModel.resolvePlatformSecret(
          deps.resumeDeps.secrets,
          orgKey,
          null,
          #slackBotToken,
          {
            slackUserId = null;
            agentId = null;
            operation = "block-actions:handle";
          },
        );
      };
    };

    if (payload.actionId == "approve_workflow") {
      // Delegate auth check + #used mutation to the model.
      let record = switch (ApprovalModel.approve(deps.approvalState, payload.actionValue, payload.userId, adminWorkspaces)) {
        case (#err(msg)) {
          await postOutcome(payload.responseUrl, ephemeralBody(msg));
          return;
        };
        case (#ok(r)) { r };
      };

      // Synchronously cancel the TTL timer before any await so it cannot race.
      cancelTurnTimer(deps, record.turnId);

      // Fire-and-forget resume via a zero-delay timer so postOutcome can proceed concurrently.
      let resumeDeps = deps.resumeDeps;
      let keyCache = deps.keyCache;
      let userId = payload.userId;
      ignore Timer.setTimer<system>(
        #nanoseconds 0,
        func() : async () {
          ignore await AgentRunner.resumeWithApproval(resumeDeps, keyCache, record, userId, botTokenOpt);
        },
      );

      // Replace the button block with a confirmation line.
      await postOutcome(payload.responseUrl, replaceOriginalBody("✅ Approved by <@" # payload.userId # ">."));
    } else {
      // Delegate auth check + #expired mutation to the model.
      let record = switch (ApprovalModel.deny(deps.approvalState, payload.actionValue, payload.userId, adminWorkspaces)) {
        case (#err(msg)) {
          await postOutcome(payload.responseUrl, ephemeralBody(msg));
          return;
        };
        case (#ok(r)) { r };
      };

      // Synchronously cancel the TTL timer before any await so it cannot race.
      cancelTurnTimer(deps, record.turnId);

      let resumeDeps = deps.resumeDeps;
      let keyCache = deps.keyCache;
      let turnId = record.turnId;
      ignore Timer.setTimer<system>(
        #nanoseconds 0,
        func() : async () {
          await AgentRunner.resumeWithDenial(resumeDeps, keyCache, turnId, "user denied", botTokenOpt);
        },
      );

      // Replace the button block with a denial line.
      await postOutcome(payload.responseUrl, replaceOriginalBody("🚫 Denied by <@" # payload.userId # ">."));
    };
  };
};
