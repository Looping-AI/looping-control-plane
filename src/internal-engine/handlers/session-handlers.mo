import Json "mo:json";
import { str; obj } "mo:json";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ─────────────────────────────────────────────────

  /// Update session policy for an agent. → POST /session/policy
  /// Body: { "agentId": N, "summaryTokenBudget": N, "maxTruncatedTokens": N }
  public func updateSessionPolicy(wrapper : Wrapper, args : Text) : async Text {
    handleResult(await wrapper.callCore(#post, "/session/policy", args));
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : Text {
    switch (result) {
      case (#ok(data)) { data };
      case (#err(e)) { errorJson(e) };
    };
  };

  private func errorJson(msg : Text) : Text {
    Json.stringify(obj([("error", str(msg))]), null);
  };
};
