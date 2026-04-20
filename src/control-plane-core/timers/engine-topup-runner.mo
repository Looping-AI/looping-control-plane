/// Engine Top-up Runner
/// Checks the internal engine canister's cycle balance and tops it up
/// if it falls below the configured threshold. Scheduled to run every 7 days.

import Principal "mo:core/Principal";
import Constants "../constants";

module {

  /// Minimal management canister interface for canister_status + deposit_cycles.
  type IC = actor {
    canister_status : shared { canister_id : Principal } -> async {
      cycles : Nat;
      status : { #running; #stopping; #stopped };
      memory_size : Nat;
      module_hash : ?Blob;
    };
    deposit_cycles : shared { canister_id : Principal } -> async ();
  };

  let ic : IC = actor ("aaaaa-aa");

  public func run(enginePrincipal : ?Principal) : async {
    #ok;
    #err : Text;
  } {
    let canisterId = switch (enginePrincipal) {
      case (null) { return #ok }; // Engine not spawned yet — nothing to top up
      case (?p) { p };
    };

    let status = await ic.canister_status({ canister_id = canisterId });

    if (status.cycles < Constants.ENGINE_MIN_CYCLES) {
      await (with cycles = Constants.ENGINE_TOPUP_CYCLES) ic.deposit_cycles({
        canister_id = canisterId;
      });
    };

    #ok;
  };
};
