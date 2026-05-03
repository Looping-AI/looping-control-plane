/// TurnCompletionService
///
/// Reduces an `AgentOrchestrateResult` to its observable effects:
///   - `#dispatched`      → mutates turn status to `#awaitingWorkflow`
///   - `#awaitingApproval`→ mutates turn status to `#awaitingApproval`
///   - `#ok`              → posts response to Slack, appends trace, completes turn `#succeeded`
///   - `#err`             → posts error text to Slack, completes turn `#failed`
///
/// Returns the combined processing steps, including the Slack post step for `#ok`/`#err`.
/// Callers that do not need the steps may `ignore` the return value.
import Array "mo:core/Array";
import Time "mo:core/Time";
import Types "../types";
import SessionModel "../models/session-model";
import ApprovalModel "../models/approval-model";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";

module {

  public type ServiceDeps = {
    sessionStores : SessionModel.SessionStores;
    approvalState : ApprovalModel.ApprovalState;
  };

  public type SlackPostCtx = {
    botToken : Text;
    channelId : Text;
    threadTs : ?Text;
    metadata : ?Types.AgentMessageMetadata;
  };

  public func apply(
    deps : ServiceDeps,
    turnId : Text,
    result : Types.AgentOrchestrateResult,
    slackCtx : SlackPostCtx,
  ) : async [Types.ProcessingStep] {
    switch (result) {
      case (#dispatched({ steps; suspension })) {
        switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
          case (?turn) { turn.status := #awaitingWorkflow(suspension) };
          case null {};
        };
        steps;
      };
      case (#awaitingApproval({ steps; suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId })) {
        switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
          case (?turn) {
            let expiresAtNs = switch (ApprovalModel.findByCode(deps.approvalState, approvalCode)) {
              case (?record) { record.expiresAtNs };
              case null { Time.now() }; // safe fallback: treat as expired immediately
            };
            turn.status := #awaitingApproval({
              suspension;
              workflowName;
              approvalCode;
              originalToolArgs;
              requestedByUserId;
              expiresAtNs;
              var timerId = null; // armed by the caller (message-handler) after this returns
            });
          };
          case null {};
        };
        steps;
      };
      case (#ok({ response; steps })) {
        let slackResult = await SlackWrapper.postMessage(
          slackCtx.botToken,
          slackCtx.channelId,
          response,
          slackCtx.threadTs,
          slackCtx.metadata,
          null,
        );
        let slackStep : Types.ProcessingStep = {
          action = "post_to_slack";
          result = switch (slackResult) {
            case (#ok(_)) { #ok };
            case (#err(e)) { #err(e) };
          };
          timestamp = Time.now();
        };
        switch (slackResult) {
          case (#ok({ ts = replyTs; channel = _ })) {
            SessionModel.appendTrace(
              deps.sessionStores,
              turnId,
              #slackPost({
                channelId = slackCtx.channelId;
                threadTs = slackCtx.threadTs;
                ts = replyTs;
              }),
            );
            let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
            SessionModel.completeTurn(deps.sessionStores, turnId, #succeeded, cost, null);
          };
          case (#err(e)) {
            Logger.log(#error, ?"TurnCompletion", "Reply post failed for turn " # turnId # ": " # e);
            let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
            SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?"Slack post failed");
          };
        };
        Array.concat(steps, [slackStep]);
      };
      case (#err({ message; steps })) {
        let errorText = "[Agent error] " # message;
        switch (
          await SlackWrapper.postMessage(
            slackCtx.botToken,
            slackCtx.channelId,
            errorText,
            slackCtx.threadTs,
            slackCtx.metadata,
            null,
          )
        ) {
          case (#ok(_)) {};
          case (#err(e)) {
            Logger.log(#error, ?"TurnCompletion", "Error post failed for turn " # turnId # ": " # e);
          };
        };
        let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
        SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?message);
        steps;
      };
    };
  };
};
