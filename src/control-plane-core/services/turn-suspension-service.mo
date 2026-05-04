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
        ignore SessionModel.suspendForWorkflow(deps.sessionStores, turnId, suspension);
        steps;
      };
      case (#awaitingApproval({ steps; suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId })) {
        let expiresAtNs = switch (ApprovalModel.findByCode(deps.approvalState, approvalCode)) {
          case (?record) { record.expiresAtNs };
          case null { Time.now() }; // safe fallback: treat as expired immediately
        };
        ignore SessionModel.suspendForApproval(
          deps.sessionStores,
          turnId,
          suspension,
          workflowName,
          approvalCode,
          originalToolArgs,
          requestedByUserId,
          expiresAtNs,
        );
        steps;
      };
      case _ { Runtime.unreachable() };
    };
  };
};
