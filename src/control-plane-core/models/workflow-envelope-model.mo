import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Time "mo:core/Time";
import List "mo:core/List";
import WorkflowTypes "../types/workflow";
import Constants "../constants";
import Nonce "../utilities/nonce";

module {

  // ── Types ──────────────────────────────────────────────────────────

  public type EnvelopeRecord = {
    nonce : Text;
    envelopeId : Nat;
    turnId : Text;
    workspaceId : Nat;
    grants : [WorkflowTypes.ScopeGrant];
    createdAtNs : Int;
    expiresAtNs : Int;
    var revoked : Bool;
    /// The engine version string accepted for this envelope (e.g. "v1", "v1.1").
    /// Stamped by the dispatch lambda after a successful engine round-trip.
    /// null until the envelope is dispatched and acknowledged.
    var dispatchedVersion : ?Text;
  };

  /// Mutable state for the envelope/token store.
  /// envelopeSalt is refreshed on every canister upgrade via raw_rand;
  /// it travels with the state so any code holding EnvelopeState can
  /// generate an envelope without threading the salt separately.
  public type EnvelopeState = {
    var nextTokenId : Nat;
    var envelopeSalt : Blob;
    envelopes : Map.Map<Text, EnvelopeRecord>;
    /// Last-known envelope version accepted by each named engine.
    /// Key = engine name (e.g. "internal-engine"), value = version string (e.g. "v1").
    /// Updated automatically on version-mismatch retries by EngineDispatchService.
    knownEngineVersions : Map.Map<Text, Text>;
  };

  // ── Constructor ────────────────────────────────────────────────────

  public func emptyState() : EnvelopeState {
    {
      var nextTokenId = 0;
      var envelopeSalt = Blob.fromArray([]);
      envelopes = Map.empty<Text, EnvelopeRecord>();
      knownEngineVersions = Map.empty<Text, Text>();
    };
  };

  // ── Issue ──────────────────────────────────────────────────────────

  /// Issue a new envelope. Generates both a unique envelopeId (Nat)
  /// and an unpredictable nonce (64-char hex) atomically from the same counter.
  /// Returns { envelopeId; nonce } so the caller can build the ExecutionEnvelope
  /// and store the nonce for later validation.
  public func issue(
    store : EnvelopeState,
    turnId : Text,
    workspaceId : Nat,
    grants : [WorkflowTypes.ScopeGrant],
  ) : { envelopeId : Nat; nonce : Text } {
    let now = Time.now();
    let envelopeId = store.nextTokenId;
    let nonce = Nonce.make(store.envelopeSalt, envelopeId, now);
    store.nextTokenId += 1;
    let record : EnvelopeRecord = {
      nonce;
      envelopeId;
      turnId;
      workspaceId;
      grants;
      createdAtNs = now;
      expiresAtNs = now + Constants.WORKFLOW_TOKEN_TTL_NS;
      var revoked = false;
      var dispatchedVersion = null;
    };

    Map.add(store.envelopes, Text.compare, nonce, record);
    { envelopeId; nonce };
  };

  // ── Validate ───────────────────────────────────────────────────────

  public func validate(
    store : EnvelopeState,
    nonce : Text,
    requiredGrant : WorkflowTypes.ScopeGrant,
  ) : Bool {
    switch (Map.get(store.envelopes, Text.compare, nonce)) {
      case (null) { false };
      case (?record) {
        if (record.revoked) { return false };
        if (Time.now() > record.expiresAtNs) { return false };
        hasGrant(record.grants, requiredGrant);
      };
    };
  };

  // ── Get Record ─────────────────────────────────────────────────────

  public func getRecord(store : EnvelopeState, nonce : Text) : ?EnvelopeRecord {
    switch (Map.get(store.envelopes, Text.compare, nonce)) {
      case (null) { null };
      case (?record) {
        if (record.revoked or Time.now() > record.expiresAtNs) { return null };
        ?record;
      };
    };
  };

  // ── Stamp Dispatched Version ───────────────────────────────────────

  /// Record the engine version that accepted this envelope.
  /// Called by the dispatch lambda after a successful engine round-trip.
  public func stampDispatchedVersion(store : EnvelopeState, nonce : Text, version : Text) {
    switch (Map.get(store.envelopes, Text.compare, nonce)) {
      case (null) {};
      case (?record) { record.dispatchedVersion := ?version };
    };
  };

  // ── Revoke ─────────────────────────────────────────────────────────

  public func revoke(store : EnvelopeState, nonce : Text) {
    switch (Map.get(store.envelopes, Text.compare, nonce)) {
      case (null) {};
      case (?record) { record.revoked := true };
    };
  };

  // ── Delete ────────────────────────────────────────────────
  /// Delete all envelope records with createdAtNs older than cutoffNs.
  /// Called by the weekly cleanup timer to GC envelopes independently of
  /// turn deletion (envelopes are retained for 30 days, turns for 90 days).
  /// Full scan is required because the map is keyed by SHA256 nonce (random
  /// order) — no chronological traversal or early-exit is possible.
  /// Returns the number of envelope records removed.
  public func deleteEnvelopesOlderThan(store : EnvelopeState, cutoffNs : Int) : Nat {
    var removed : Nat = 0;
    let toRemove = List.empty<Text>();
    for ((nonce, record) in Map.entries(store.envelopes)) {
      if (record.createdAtNs < cutoffNs) {
        List.add(toRemove, nonce);
      };
    };
    for (nonce in List.values(toRemove)) {
      Map.remove(store.envelopes, Text.compare, nonce);
      removed += 1;
    };
    removed;
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func hasGrant(
    grants : [WorkflowTypes.ScopeGrant],
    required : WorkflowTypes.ScopeGrant,
  ) : Bool {
    for (grant in grants.vals()) {
      let matched = switch (grant, required) {
        case (#workspace(g), #workspace(r)) {
          coversAccess(g.access, r.access);
        };
        case (#agents(g), #agents(r)) { coversAccess(g.access, r.access) };
        case (#agent(g), #agent(r)) {
          g.id == r.id and coversAccess(g.access, r.access);
        };
        case (#slackQueue(g), #slackQueue(r)) {
          coversAccess(g.access, r.access);
        };
        case (#session(g), #session(r)) { coversAccess(g.access, r.access) };
        case (_, _) { false };
      };
      if (matched) { return true };
    };
    false;
  };

  private func coversAccess(
    held : WorkflowTypes.ScopeAccess,
    required : WorkflowTypes.ScopeAccess,
  ) : Bool {
    switch (required) {
      case (#read) { true }; // any access level covers read
      case (#write) { held == #write };
    };
  };

};
