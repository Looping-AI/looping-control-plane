/// Execution Types — re-export shim
/// Internal-engine files import from here instead of reaching into control-plane-core directly.
/// The canonical source remains src/control-plane-core/types/execution.mo.

import E "../control-plane-core/types/execution";

module {
  public type HttpMethod = E.HttpMethod;
  public type ScopeAccess = E.ScopeAccess;
  public type ScopeGrant = E.ScopeGrant;
  public type OperationPermit = E.OperationPermit;
  public type ChatRole = E.ChatRole;
  public type ChatMessage = E.ChatMessage;
  public type ExecutionConstraints = E.ExecutionConstraints;
  public type ExecutionSecrets = E.ExecutionSecrets;
  public type ExecutionEnvelope = E.ExecutionEnvelope;
  public type ExecutionStats = E.ExecutionStats;
  public type ExecutionStatus = E.ExecutionStatus;
  public type ExecutionResult = E.ExecutionResult;
  public type SummarizedStep = E.SummarizedStep;
  public type ExecutionEvent = E.ExecutionEvent;
  public type AsyncEffect = E.AsyncEffect;
  public type HandleResult = E.HandleResult;
};
