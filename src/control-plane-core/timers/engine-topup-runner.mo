/// Engine Top-up Runner
/// Checks the internal engine canister's cycle balance and tops it up
/// if it falls below the configured threshold. Scheduled to run every 7 days.

import Error "mo:core/Error";
import Principal "mo:core/Principal";
import { ic } "mo:ic";
import IcCompat "../wrappers/ic-management-compat";
import Constants "../constants";

module {

  public func run(enginePrincipal : ?Principal) : async {
    #ok;
    #err : Text;
  } {
    let canisterId = switch (enginePrincipal) {
      case (null) { return #ok }; // Engine not spawned yet — nothing to top up
      case (?p) { p };
    };

    let status = try {
      await IcCompat.ic.canister_status({ canister_id = canisterId });
    } catch (e) {
      return #err("canister_status failed: " # Error.message(e));
    };

    if (status.cycles < Constants.ENGINE_MIN_CYCLES) {
      try {
        await (with cycles = Constants.ENGINE_TOPUP_CYCLES) ic.deposit_cycles({
          canister_id = canisterId;
        });
      } catch (e) {
        return #err("deposit_cycles failed: " # Error.message(e));
      };
    };

    #ok;
  };
};
