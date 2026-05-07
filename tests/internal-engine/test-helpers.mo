import Nat "mo:core/Nat";
import WorkflowTypes "../../src/internal-engine/workflow-types";

// ============================================
// Internal Engine Test Helpers
// ============================================

module {

  // ── Envelope builders ────────────────────────────────────────────

  /// Builds a minimal EnvelopePayload for unit tests.
  /// Includes a dummy OpenRouter API key so the engine's `hasApiKey` guard passes.
  public func minimalEnvelope(
    envelopeId : Nat,
    agentName : Text,
    prompt : Text,
  ) : WorkflowTypes.EnvelopePayload {
    {
      envelopeId;
      dispatchedVersion = ?"v1";
      catalogHash = null;
      requestId = "req-test-" # Nat.toText(envelopeId);
      agentId = 0;
      agentName;
      workspaceId = 0;
      workflowName = "wf-test";
      workflowArguments = null;
      model = "openai/gpt-oss-120b";
      messages = [{ role = #user; content = prompt }];
      instructions = "You are a test assistant.";
      constraints = { maxRounds = 3; maxTokenBudget = null };
      secrets = { apiKeys = [("openrouter", "test-key-placeholder")] };
      scopeGrants = [];
      envelopeNonce = "nonce-" # Nat.toText(envelopeId);
    };
  };

};
