import List "mo:core/List";

// ============================================
// Stub Core Canister
// ============================================
//
// A minimal substitute for the control-plane-core canister, used in
// internal-engine integration tests.
//
// Implements the CoreApi `executionApi` interface and records every call so
// TypeScript tests can assert which paths were hit and with what payloads.
//
// Default behaviour: return #ok("{}") for every call.  This is sufficient
// for guard-rejection tests and simple end-to-end completion tests.

persistent actor class StubCoreCanister() = self {

  // ── Recorded call type ────────────────────────────────────────────

  public type RecordedCall = {
    method : { #get; #post; #delete };
    path : Text;
    body : Text;
  };

  // ── Mutable call log (stable across upgrades) ─────────────────────

  var calls : List.List<RecordedCall> = List.empty<RecordedCall>();

  // ── CoreApi implementation ────────────────────────────────────────

  /// Stub implementation of the Core executionApi.
  /// Records the call and returns #ok("{}") for all paths.
  public shared func executionApi(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
  ) : async { #ok : Text; #err : Text } {
    List.add(calls, { method; path; body });
    #ok("{}");
  };

  // ── Inspection helpers ────────────────────────────────────────────

  /// Return all recorded executionApi calls in the order they were received.
  public query func getRecordedCalls() : async [RecordedCall] {
    List.toArray(calls);
  };

  /// Clear all recorded calls.  Call in beforeEach for test isolation.
  public func clearRecordedCalls() : async () {
    calls := List.empty<RecordedCall>();
  };

};
