import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import ExecutionTypes "../types/execution";
import Constants "../constants";

module {

  // ── Types ──────────────────────────────────────────────────────────

  public type TokenRecord = {
    nonce : Text;
    envelopeId : Text;
    turnId : Text;
    workspaceId : Nat;
    grants : [ExecutionTypes.ScopeGrant];
    permits : [ExecutionTypes.OperationPermit];
    createdAtNs : Int;
    expiresAtNs : Int;
    var revoked : Bool;
  };

  public type TokenStore = {
    var nextTokenId : Nat;
    tokens : Map.Map<Text, TokenRecord>;
  };

  // ── Constructor ────────────────────────────────────────────────────

  public func emptyStore() : TokenStore {
    {
      var nextTokenId = 0;
      tokens = Map.empty<Text, TokenRecord>();
    };
  };

  // ── Issue ──────────────────────────────────────────────────────────

  public func issue(
    store : TokenStore,
    envelopeId : Text,
    turnId : Text,
    workspaceId : Nat,
    grants : [ExecutionTypes.ScopeGrant],
    permits : [ExecutionTypes.OperationPermit],
  ) : Text {
    cleanup(store);

    let nonce = Nat.toText(store.nextTokenId);
    store.nextTokenId += 1;

    let now = Time.now();
    let record : TokenRecord = {
      nonce;
      envelopeId;
      turnId;
      workspaceId;
      grants;
      permits;
      createdAtNs = now;
      expiresAtNs = now + Constants.EXECUTION_TOKEN_TTL_NS;
      var revoked = false;
    };

    Map.add(store.tokens, Text.compare, nonce, record);
    nonce;
  };

  // ── Validate ───────────────────────────────────────────────────────

  public func validate(
    store : TokenStore,
    nonce : Text,
    requiredGrant : ExecutionTypes.ScopeGrant,
  ) : Bool {
    switch (Map.get(store.tokens, Text.compare, nonce)) {
      case (null) { false };
      case (?record) {
        if (record.revoked) { return false };
        if (Time.now() > record.expiresAtNs) { return false };
        hasGrant(record.grants, requiredGrant);
      };
    };
  };

  // ── Get Record ─────────────────────────────────────────────────────

  public func getRecord(store : TokenStore, nonce : Text) : ?TokenRecord {
    switch (Map.get(store.tokens, Text.compare, nonce)) {
      case (null) { null };
      case (?record) {
        if (record.revoked or Time.now() > record.expiresAtNs) { return null };
        ?record;
      };
    };
  };

  // ── Revoke ─────────────────────────────────────────────────────────

  public func revoke(store : TokenStore, nonce : Text) {
    switch (Map.get(store.tokens, Text.compare, nonce)) {
      case (null) {};
      case (?record) { record.revoked := true };
    };
  };

  // ── Cleanup ────────────────────────────────────────────────────────

  public func cleanup(store : TokenStore) {
    let now = Time.now();
    let toRemove = List.empty<Text>();

    for ((nonce, record) in Map.entries(store.tokens)) {
      if (record.revoked or now > record.expiresAtNs) {
        List.add(toRemove, nonce);
      };
    };

    for (nonce in List.values(toRemove)) {
      Map.remove(store.tokens, Text.compare, nonce);
    };
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
    store : TokenStore,
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

};
