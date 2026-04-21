import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Int "mo:core/Int";
import Time "mo:core/Time";
import List "mo:core/List";
import Set "mo:core/Set";
import Sha256 "mo:sha2/Sha256";
import ExecutionTypes "../types/execution";
import Constants "../constants";

module {

  // ── Types ──────────────────────────────────────────────────────────

  public type EnvelopeRecord = {
    nonce : Text;
    envelopeId : Nat;
    turnId : Text;
    workspaceId : Nat;
    grants : [ExecutionTypes.ScopeGrant];
    permits : [ExecutionTypes.OperationPermit];
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
    grants : [ExecutionTypes.ScopeGrant],
    permits : [ExecutionTypes.OperationPermit],
  ) : { envelopeId : Nat; nonce : Text } {
    let now = Time.now();
    let envelopeId = store.nextTokenId;
    let nonce = makeNonce(store.envelopeSalt, envelopeId, now);
    store.nextTokenId += 1;
    let record : EnvelopeRecord = {
      nonce;
      envelopeId;
      turnId;
      workspaceId;
      grants;
      permits;
      createdAtNs = now;
      expiresAtNs = now + Constants.EXECUTION_TOKEN_TTL_NS;
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
    requiredGrant : ExecutionTypes.ScopeGrant,
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
  /// Called by the weekly turn-cleanup timer when turns are hard-deleted,
  /// so that envelope records are GC'd together with their owning turn.
  /// Returns the number of envelope records removed.
  public func deleteByTurnIds(store : EnvelopeState, turnIds : [Text]) : Nat {
    var removed : Nat = 0;
    let turnIdSet = Set.fromArray<Text>(turnIds, Text.compare);
    let toRemove = List.empty<Text>();
    for ((nonce, record) in Map.entries(store.envelopes)) {
      if (Set.contains(turnIdSet, Text.compare, record.turnId)) {
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
    grants : [ExecutionTypes.ScopeGrant],
    required : ExecutionTypes.ScopeGrant,
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
    held : ExecutionTypes.ScopeAccess,
    required : ExecutionTypes.ScopeAccess,
  ) : Bool {
    switch (required) {
      case (#read) { true }; // any access level covers read
      case (#write) { held == #write };
    };
  };

  // ── Permit checking ────────────────────────────────────────────────

  /// Check if the token identified by `nonce` carries a matching OperationPermit.
  public func hasPermit(
    store : EnvelopeState,
    nonce : Text,
    required : ExecutionTypes.OperationPermit,
  ) : Bool {
    switch (getRecord(store, nonce)) {
      case (null) { false };
      case (?record) { permitMatches(record.permits, required) };
    };
  };

  private func permitMatches(
    permits : [ExecutionTypes.OperationPermit],
    required : ExecutionTypes.OperationPermit,
  ) : Bool {
    for (permit in permits.vals()) {
      let matched = switch (permit, required) {
        case (#deleteWorkspace(p), #deleteWorkspace(r)) {
          p.workspaceId == r.workspaceId;
        };
        case (#setAdminChannel(p), #setAdminChannel(r)) {
          p.channelId == r.channelId;
        };
        case (_, _) { false };
      };
      if (matched) { return true };
    };
    false;
  };

  // ── Nonce generation ───────────────────────────────────────────────

  /// Encode a Nat as 8 big-endian bytes.
  private func natToBytes8(n : Nat) : [Nat8] {
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        Nat8.fromNat((n / (256 ** (7 - i))) % 256);
      },
    );
  };

  /// Hex-encode a single byte as two lowercase hex characters.
  private func byteToHex(b : Nat8) : Text {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    digits[Nat8.toNat(b) / 16] # digits[Nat8.toNat(b) % 16];
  };

  /// Produce an unpredictable 64-char hex nonce:
  ///   SHA256(salt || counter-bytes(8) || timestamp-bytes(8))
  /// - salt: per-canister entropy refreshed on every upgrade via raw_rand
  /// - counter: monotonically increasing — prevents nonce reuse within a salt cycle
  /// - timestamp: adds an additional timing dimension to the preimage
  private func makeNonce(salt : Blob, counter : Nat, now : Int) : Text {
    let saltArr = Blob.toArray(salt);
    let counterArr = natToBytes8(counter);
    let timeArr = natToBytes8(Int.abs(now));
    let input = List.empty<Nat8>();
    for (b in saltArr.vals()) { List.add(input, b) };
    for (b in counterArr.vals()) { List.add(input, b) };
    for (b in timeArr.vals()) { List.add(input, b) };
    let hash = Sha256.fromArray(#sha256, List.toArray(input));
    let hashBytes = Blob.toArray(hash);
    var hex = "";
    for (b in hashBytes.vals()) {
      hex #= byteToHex(b);
    };
    hex;
  };

};
