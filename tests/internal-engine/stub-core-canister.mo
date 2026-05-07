import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";

// ============================================
// Stub Core Canister
// ============================================
//
// A minimal substitute for the control-plane-core canister, used in
// internal-engine integration tests.
//
// Implements the CoreApi `workflowApi` interface and records every call so
// TypeScript tests can assert which paths were hit and with what payloads.
//
// Default behaviour: return #ok("{}") for every call.  Tests can call
// setPathResponse(path, json) to inject a realistic response for a specific
// path, so the LLM receives meaningful data and can complete the turn.

persistent actor class StubCoreCanister() = self {

  // ── Recorded call type ────────────────────────────────────────────

  public type RecordedCall = {
    method : { #get; #post; #delete };
    path : Text;
    body : Text;
  };

  // ── Mutable call log (stable across upgrades) ─────────────────────

  var calls : List.List<RecordedCall> = List.empty<RecordedCall>();

  // ── Per-path response overrides ───────────────────────────────────

  var pathOverrides : Map.Map<Text, Text> = Map.empty<Text, Text>();

  // ── CoreApi implementation ────────────────────────────────────────

  /// Stub implementation of the Core workflowApi.
  /// Records the call and returns the configured path override, or "{}" if none.
  public shared func workflowApi(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
  ) : async { #ok : Text; #err : Text } {
    List.add(calls, { method; path; body });
    let response = switch (Map.get(pathOverrides, Text.compare, path)) {
      case (?override) { override };
      case null { "{}" };
    };
    #ok(response);
  };

  // ── Inspection helpers ────────────────────────────────────────────

  /// Return all recorded workflowApi calls in the order they were received.
  public query func getRecordedCalls() : async [RecordedCall] {
    List.toArray(calls);
  };

  /// Clear all recorded calls and path overrides.  Call in beforeEach for test isolation.
  public func clearRecordedCalls() : async () {
    calls := List.empty<RecordedCall>();
    pathOverrides := Map.empty<Text, Text>();
  };

  /// Configure the response body returned for a specific path.
  /// Persists until the next clearRecordedCalls() call.
  public func setPathResponse(path : Text, response : Text) : async () {
    Map.add(pathOverrides, Text.compare, path, response);
  };

};
