import Map "mo:core/Map";
import Set "mo:core/Set";
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
    #approved;
    #denied;
  };

  public type ApprovalRecord = {
    code : Text;
    workflowName : Text;
    originalArgs : Text;
    workspaceId : Nat;
    agentId : Nat;
    turnId : Text;
    requestedByUserId : Text;
    requestedAt : Int;
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
    originalArgs : Text,
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
      originalArgs;
      workspaceId;
      agentId;
      turnId;
      requestedByUserId;
      requestedAt = now;
      var status = #pending;
    };
    Map.add(state.approvals, Text.compare, code, record);
    code;
  };

  /// Look up an approval record by code.
  public func findByCode(state : ApprovalState, code : Text) : ?ApprovalRecord {
    Map.get(state.approvals, Text.compare, code);
  };

  /// Returns the absolute nanosecond deadline for the human approval window.
  /// After this timestamp, the record can no longer be approved or denied.
  public func approvalWindowDeadline(record : ApprovalRecord) : Int {
    record.requestedAt + Constants.APPROVAL_TTL_NS;
  };

  /// Returns true when the human approval window has passed (requestedAt + TTL).
  /// After this point, the record can no longer be approved or denied.
  public func isApprovalWindowExpired(record : ApprovalRecord, now : Int) : Bool {
    now > record.requestedAt + Constants.APPROVAL_TTL_NS;
  };

  /// Returns true when the workflow execution window has passed (requestedAt + 2 × TTL).
  /// After this point, the internal engine can no longer use an #approved record.
  public func isWorkflowWindowExpired(record : ApprovalRecord, now : Int) : Bool {
    now > record.requestedAt + (2 * Constants.APPROVAL_TTL_NS);
  };

  /// Approve an approval code: must exist, be #pending, within the approval window,
  /// and be authorized.
  ///
  /// Authorized when either:
  ///   - `userId` is the original requester, OR
  ///   - `adminWorkspaces` contains the workspace ID on the approval record.
  ///
  /// On success marks the record #approved and returns it.
  public func approve(
    state : ApprovalState,
    code : Text,
    userId : Text,
    adminWorkspaces : Set.Set<Nat>,
  ) : Result.Result<ApprovalRecord, Text> {
    switch (Map.get(state.approvals, Text.compare, code)) {
      case (null) { #err("Invalid approval code.") };
      case (?record) {
        switch (record.status) {
          case (#approved) { #err("This workflow has already been approved.") };
          case (#denied) { #err("This workflow was denied.") };
          case (#pending) {
            if (isApprovalWindowExpired(record, Time.now())) {
              return #err("This approval code has expired. Please request the agent to run the workflow again.");
            };
            if (record.requestedByUserId != userId and not Set.contains(adminWorkspaces, Nat.compare, record.workspaceId)) {
              return #err("Only the original requester or a workspace admin can approve this workflow.");
            };
            record.status := #approved;
            #ok(record);
          };
        };
      };
    };
  };

  /// Deny an approval code: must exist, be #pending, within the approval window,
  /// and be authorized.
  ///
  /// Authorized when either:
  ///   - `userId` is the original requester, OR
  ///   - `adminWorkspaces` contains the workspace ID on the approval record.
  ///
  /// On success marks the record #denied and returns it.
  public func deny(
    state : ApprovalState,
    code : Text,
    userId : Text,
    adminWorkspaces : Set.Set<Nat>,
  ) : Result.Result<ApprovalRecord, Text> {
    switch (Map.get(state.approvals, Text.compare, code)) {
      case (null) { #err("Invalid approval code.") };
      case (?record) {
        switch (record.status) {
          case (#approved) { #err("This workflow has already been approved.") };
          case (#denied) { #err("This workflow was already denied.") };
          case (#pending) {
            if (isApprovalWindowExpired(record, Time.now())) {
              return #err("This approval code has expired, no need for further action.");
            };
            if (record.requestedByUserId != userId and not Set.contains(adminWorkspaces, Nat.compare, record.workspaceId)) {
              return #err("Only the original requester or a workspace admin can deny this workflow.");
            };
            record.status := #denied;
            #ok(record);
          };
        };
      };
    };
  };

};
