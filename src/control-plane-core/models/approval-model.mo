import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Time "mo:core/Time";
import Result "mo:core/Result";
import Nonce "../utilities/nonce";
import Constants "../constants";

module {

  // ── Types ──────────────────────────────────────────────────────────

  public type ApprovalStatus = {
    #pending;
    #used;
    #expired;
  };

  public type ApprovalRecord = {
    code : Text;
    workflowName : Text;
    renderedArgs : Text;
    workspaceId : Nat;
    agentId : Nat;
    turnId : Text;
    requestedByUserId : Text;
    requestedAt : Int;
    expiresAtNs : Int;
    var status : ApprovalStatus;
  };

  public type ApprovalState = {
    var counter : Nat;
    var approvalSalt : Blob;
    approvals : Map.Map<Text, ApprovalRecord>;
  };

  // ── Constructor ────────────────────────────────────────────────────

  public func emptyState() : ApprovalState {
    {
      var counter = 0;
      var approvalSalt = Blob.fromArray([]);
      approvals = Map.empty<Text, ApprovalRecord>();
    };
  };

  // ── Operations ─────────────────────────────────────────────────────

  /// Generate a new approval code, create the record, and return the code.
  public func request(
    state : ApprovalState,
    workflowName : Text,
    renderedArgs : Text,
    workspaceId : Nat,
    agentId : Nat,
    turnId : Text,
    requestedByUserId : Text,
  ) : Text {
    let now = Time.now();
    let code = Nonce.make(state.approvalSalt, state.counter, now);
    state.counter += 1;
    let record : ApprovalRecord = {
      code;
      workflowName;
      renderedArgs;
      workspaceId;
      agentId;
      turnId;
      requestedByUserId;
      requestedAt = now;
      expiresAtNs = now + Constants.APPROVAL_TTL_NS;
      var status = #pending;
    };
    Map.add(state.approvals, Text.compare, code, record);
    code;
  };

  /// Look up an approval record by code.
  public func findByCode(state : ApprovalState, code : Text) : ?ApprovalRecord {
    Map.get(state.approvals, Text.compare, code);
  };

  /// Validate an approval code: must exist, be #pending, and belong to the requesting user.
  /// On success marks the record #used and returns it.
  public func validate(
    state : ApprovalState,
    code : Text,
    requestedByUserId : Text,
  ) : Result.Result<ApprovalRecord, Text> {
    switch (Map.get(state.approvals, Text.compare, code)) {
      case (null) { #err("Invalid approval code.") };
      case (?record) {
        switch (record.status) {
          case (#expired) {
            #err("This approval code has expired. Please request the agent to run the workflow again.");
          };
          case (#used) { #err("This approval code has already been used.") };
          case (#pending) {
            if (record.requestedByUserId != requestedByUserId) {
              return #err("Only the user who requested this approval can approve it.");
            };
            record.status := #used;
            #ok(record);
          };
        };
      };
    };
  };

  /// Mark an approval code as expired. Called by the TTL timer (5.2.1.1).
  public func expire(state : ApprovalState, code : Text) {
    switch (Map.get(state.approvals, Text.compare, code)) {
      case (null) {};
      case (?record) { record.status := #expired };
    };
  };

};
