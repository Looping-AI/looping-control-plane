import Nat "mo:core/Nat";
import ExecutionTypes "../../src/internal-engine/execution-types";

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
  ) : ExecutionTypes.EnvelopePayload {
    {
      envelopeId;
      requestId = "req-test-" # Nat.toText(envelopeId);
      agentId = 0;
      workspaceId = 0;
      workflowName = "wf-test";
      agentName;
      dispatchedVersion = ?"v1";
      instructions = "You are a test assistant.";
      messages = [{ role = #user; content = prompt }];
      constraints = { maxRounds = 3; maxTokenBudget = null };
      model = "openai/gpt-oss-120b";
      secrets = { apiKeys = [("openrouter", "test-key-placeholder")] };
      scopeGrants = [];
      envelopeNonce = "nonce-" # Nat.toText(envelopeId);
      catalogHash = null;
    };
  };

};
