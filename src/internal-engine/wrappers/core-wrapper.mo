import Json "mo:json";
import List "mo:core/List";
import ExecutionTypes "../execution-types";

module {

  // ── Actor type ─────────────────────────────────────────────────────

  /// The Core canister actor interface used by the internal engine.
  public type CoreActor = actor {
    executionApi : shared ({ #get; #post; #delete }, Text, Text) -> async {
      #ok : Text;
      #err : Text;
    };
  };

  // ── Wrapper class ──────────────────────────────────────────────────

  /// Bundles the Core canister actor and the envelope nonce for the
  /// current execution. Pass a single `CoreWrapper` instance downstream
  /// instead of threading (core, envelopeNonce) as separate parameters.
  public class CoreWrapper(coreActor : CoreActor, envelopeNonce : Text) {

    /// Call Core's execution API, automatically injecting the envelope nonce.
    public func callCore(
      method : ExecutionTypes.HttpMethod,
      path : Text,
      body : Text,
    ) : async { #ok : Text; #err : Text } {
      switch (injectNonce(body, envelopeNonce)) {
        case (#err(e)) { #err(e) };
        case (#ok(enrichedBody)) {
          await coreActor.executionApi(method, path, enrichedBody);
        };
      };
    };
  };

  // ── Nonce injection (private) ──────────────────────────────────────

  private func injectNonce(body : Text, nonce : Text) : {
    #ok : Text;
    #err : Text;
  } {
    switch (Json.parse(body)) {
      case (#ok(#object_(entries))) {
        let fields = List.empty<(Text, Json.Json)>();
        List.add(fields, ("envelopeNonce", #string(nonce)));
        for ((k, v) in entries.vals()) {
          if (k != "envelopeNonce") {
            List.add(fields, (k, v));
          };
        };
        #ok(Json.stringify(#object_(List.toArray(fields)), null));
      };
      case (#ok(_)) {
        #err("Invalid request: body must be a JSON object");
      };
      case (#err(parseError)) {
        #err("Invalid request: body is not valid JSON (" # Json.errToText(parseError) # ")");
      };
    };
  };

};
