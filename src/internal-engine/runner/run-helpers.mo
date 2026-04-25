/// Run Helpers
/// Constructor and utility functions for RunRecord values.

import ExecutionTypes "../execution-types";
import RunTypes "./run-types";

module {

  /// Build a fresh RunRecord from an envelope, stamped with enqueuedAt.
  public func fromEnvelope(envelope : ExecutionTypes.EnvelopePayload, now : Int) : RunTypes.RunRecord {
    {
      envelopeId = envelope.envelopeId;
      requestId = envelope.requestId;
      agentName = envelope.agentName;
      workflowId = envelope.workflowId;
      envelope;
      enqueuedAt = now;
      claimedAt = null;
      completedAt = null;
      failedAt = null;
      failedError = "";
      status = null;
      stats = null;
      steps = [];
      coreEmitResult = null;
    };
  };

};
