/// Workflow Types — re-export shim
/// Internal-engine files import from here instead of reaching into control-plane-core directly.
/// The canonical source remains src/control-plane-core/types/workflow.mo.

import E "../control-plane-core/types/workflow";

module {
  public type HttpMethod = E.HttpMethod;
  public type ScopeAccess = E.ScopeAccess;
  public type ScopeGrant = E.ScopeGrant;
  public type ChatRole = E.ChatRole;
  public type ChatMessage = E.ChatMessage;
  public type WorkflowConstraints = E.WorkflowConstraints;
  public type WorkflowSecrets = E.WorkflowSecrets;
  public type EnvelopePayload = E.EnvelopePayload;
  public type WorkflowStats = E.WorkflowStats;
  public type WorkflowStatus = E.WorkflowStatus;
  public type WorkflowResult = E.WorkflowResult;
  public type SummarizedStep = E.SummarizedStep;
  public type WorkflowEvent = E.WorkflowEvent;
  public type AsyncEffect = E.AsyncEffect;
  public type HandleResult = E.HandleResult;
};
