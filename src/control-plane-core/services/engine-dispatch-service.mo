import Map "mo:core/Map";
import Text "mo:core/Text";
import Json "mo:json";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import ExecutionTypes "../types/execution";
import InternalEngine "../../internal-engine/main";
import Logger "../utilities/logger";

module {

  /// The map key used to look up / store the known version for the internal engine.
  let ENGINE_NAME : Text = "internal-engine";

  /// Dispatch an envelope to the internal engine, handling version negotiation
  /// and a single retry automatically.
  ///
  /// On a version-mismatch response (`{"envelopeVersionRequired":"vX"}`):
  ///   - updates `envelopeState.knownEngineVersions` for the engine name
  ///   - retries once with the required version
  ///
  /// Throws if the inter-canister call itself fails (caller should catch with try/catch).
  ///
  /// Parameter order: state first, then engine, then payload (per AGENTS.md convention).
  public func dispatch(
    envelopeState : ExecutionEnvelopeModel.EnvelopeState,
    engine : InternalEngine.InternalEngine,
    envelope : ExecutionTypes.EnvelopePayload,
  ) : async { #ok; #err : Text } {
    let nonce = envelope.envelopeNonce;
    let knownVersion = switch (Map.get(envelopeState.knownEngineVersions, Text.compare, ENGINE_NAME)) {
      case (?v) { v };
      case null { "v1" };
    };
    let stamped = {
      envelope with dispatchedVersion = ?knownVersion
    };
    switch (await engine.execute(stamped)) {
      case (#ok) {
        ExecutionEnvelopeModel.stampDispatchedVersion(envelopeState, nonce, knownVersion);
        #ok;
      };
      case (#err(msg)) {
        // Check for the version-mismatch JSON protocol: {"envelopeVersionRequired":"vX"}
        // The same protocol is used by future HTTP engines so no engine-specific branching is needed.
        switch (Json.parse(msg)) {
          case (#ok(json)) {
            switch (Json.get(json, "envelopeVersionRequired")) {
              case (?#string(requiredVersion)) {
                // Engine told us which version it needs — update the cached version and retry once.
                Logger.log(#info, ?"EnvelopeVersion", "Version sync: " # knownVersion # " → " # requiredVersion);
                Map.add(envelopeState.knownEngineVersions, Text.compare, ENGINE_NAME, requiredVersion);
                let retried = {
                  stamped with dispatchedVersion = ?requiredVersion
                };
                switch (await engine.execute(retried)) {
                  case (#ok) {
                    ExecutionEnvelopeModel.stampDispatchedVersion(envelopeState, nonce, requiredVersion);
                    #ok;
                  };
                  case (#err(retryMsg)) { #err(retryMsg) };
                };
              };
              case (_) { #err(msg) };
            };
          };
          case (#err(_)) { #err(msg) };
        };
      };
    };
  };
};
