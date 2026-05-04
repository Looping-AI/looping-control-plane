/// TurnSuspensionService
///
/// Handles the suspension outcomes of `AgentOrchestrateResult` (no Slack I/O):
///   - `#dispatched`      → mutates turn status to `#awaitingWorkflow`
///   - `#awaitingApproval`→ mutates turn status to `#awaitingApproval`
///
/// This is a synchronous operation. Returns the processing steps from the result payload.
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Types "../types";
import SessionModel "../models/session-model";
import ApprovalModel "../models/approval-model";

module {

  public type ServiceDeps = {
    sessionStores : SessionModel.SessionStores;
    approvalState : ApprovalModel.ApprovalState;
  };

  public func suspend(
    deps : ServiceDeps,
    turnId : Text,
    result : Types.AgentOrchestrateResult,
  ) : [Types.ProcessingStep] {
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
      case _ { Runtime.unreachable() };
    };
  };
};
