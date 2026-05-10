/// Compatibility shim for `ic.canister_status`.
///
/// ic@4.0.0 added `snapshot_visibility : SnapshotVisibility` as a **required** field in
/// `DefiniteCanisterSettings`. The PocketIC server bundled in @dfinity/pic does not yet
/// return this field, so the Motoko Candid decoder traps with
/// "IDL error: did not find field snapshot_visibility in record".
///
/// This module re-declares the management canister actor with a minimal
/// `CanisterStatusResult` that omits `snapshot_visibility`. Candid's record subtyping
/// rules mean the decoder ignores extra fields in real-IC responses, so the same code
/// works on both PocketIC (missing field) and mainnet (extra field silently dropped).
///
/// TODO: Remove this module and replace all usages with `import { ic } "mo:ic"` once
/// the PocketIC server bundled in @dfinity/pic emits `snapshot_visibility` in
/// canister_status responses (the field was added to the IC spec and ic@4.0.0 but the
/// bundled server does not yet return it).

import Principal "mo:core/Principal";

module {

  /// Minimal subset of DefiniteCanisterSettings — contains only the fields our code
  /// actually accesses. `snapshot_visibility` is intentionally absent so that the
  /// Candid decoder succeeds against PocketIC responses that pre-date the field.
  public type DefiniteCanisterSettings = {
    freezing_threshold : Nat;
    controllers : [Principal];
  };

  /// Minimal subset of CanisterStatusResult — contains only the fields our code
  /// actually accesses. Extra fields in real-IC responses are silently ignored.
  public type CanisterStatusResult = {
    cycles : Nat;
    idle_cycles_burned_per_day : Nat;
    status : { #stopped; #stopping; #running };
    memory_size : Nat;
    settings : DefiniteCanisterSettings;
  };

  /// Management canister actor typed with the compat CanisterStatusResult so that
  /// responses from PocketIC (which lacks snapshot_visibility) decode successfully.
  public let ic = actor ("aaaaa-aa") : actor {
    canister_status : shared { canister_id : Principal } -> async CanisterStatusResult;
  };
};
