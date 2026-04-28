import Json "mo:json";
import { obj } "mo:json";
import ToolTypes "../tools/tool-types";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ─────────────────────────────────────────────────

  /// Update session policy for an agent. → POST /session/policy
  /// Body: { "agentId": N, "summaryTokenBudget": N, "maxTruncatedTokens": N }
  public func updateSessionPolicy(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#post, "/session/policy", args));
  };

  // ── Helpers ────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : ToolTypes.ToolCallOutcome {
    switch (result) {
      case (#ok(data)) { #ok(data) };
      case (#err(e)) { #err(e) };
    };
  };
};
