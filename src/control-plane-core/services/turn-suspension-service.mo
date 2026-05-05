/// TurnSuspensionService
///
/// Handles the suspension outcomes of `AgentOrchestrateResult` (no Slack I/O):
///   - `#dispatched`      → mutates turn status to `#awaitingWorkflow`
///   - `#awaitingApproval`→ mutates turn status to `#awaitingApproval`
///
/// This is a synchronous operation. Returns the processing steps from the result payload.
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
        ignore SessionModel.suspendForWorkflow(deps.sessionStores, turnId, suspension);
        steps;
      };
      case (#awaitingApproval({ steps; suspension; approvalCode })) {
        let expiresAtNs = switch (ApprovalModel.findByCode(deps.approvalState, approvalCode)) {
          case (?record) { ApprovalModel.approvalWindowDeadline(record) };
          case null { Runtime.unreachable() };
        };
        ignore SessionModel.suspendForApproval(
          deps.sessionStores,
          turnId,
          suspension,
          approvalCode,
          expiresAtNs,
        );
        steps;
      };
      case _ { Runtime.unreachable() };
    };
  };
};
