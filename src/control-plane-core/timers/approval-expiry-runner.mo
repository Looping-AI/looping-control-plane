/// Approval Expiry Runner
///
/// Periodic timer task that scans all pending approvals and fires
/// `AgentRunner.resumeWithDenial` for any that have exceeded their TTL.
///
/// Registered in the timer registry with a 5-minute interval. An approval that
/// expires at hour 1:00 will be noticed and denied no later than 1:05 — a
/// negligible delay for a 60-minute approval window.
///
/// Recovery after upgrades is automatic: the runner re-registers on every upgrade
/// via `scheduleAll`, so no per-turn timer state needs to survive the upgrade.

import Map "mo:core/Map";
import Time "mo:core/Time";
import Error "mo:core/Error";
import KeyDerivationService "../services/key-derivation-service";
import AgentRunner "../agents/agent-runner";
import Logger "../utilities/logger";

module {

  /// Scan all turns for expired approvals and deny them.
  /// `deps` is passed directly to `AgentRunner.resumeWithDenial`.
  /// Returns #ok on success; #err with a message if a critical failure occurs.
  public func run(
    deps : AgentRunner.ResumeDeps,
    keyCache : KeyDerivationService.KeyCache,
  ) : async { #ok; #err : Text } {
    let now = Time.now();
    for ((_agentId, agentTurns) in Map.entries(deps.sessionStores.turns)) {
      for ((_turnNum, turn) in Map.entries(agentTurns)) {
        switch (turn.status) {
          case (#awaitingApproval(data)) {
            if (data.expiresAtNs <= now) {
              let tId = turn.turnId;
              Logger.log(
                #info,
                ?"ApprovalExpiry",
                "Approval expired for turn " # tId # " — resuming with denial",
              );
              try {
                await AgentRunner.resumeWithDenial(deps, keyCache, tId, "approval timed out", null);
              } catch (e) {
                Logger.log(
                  #error,
                  ?"ApprovalExpiry",
                  "resumeWithDenial failed for turn " # tId # ": " # Error.message(e),
                );
              };
            };
          };
          case (_) {};
        };
      };
    };
    #ok;
  };

};
