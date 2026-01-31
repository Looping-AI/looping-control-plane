import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Array "mo:core/Array";

module {
  // ============================================
  // Types
  // ============================================

  public type AuthStep = {
    #IsOrgOwner; // Caller must be the org owner
    #IsOrgAdmin; // Caller must be an org admin
    #AnyWorkspaceAdmin; // Caller must be admin of any workspace
    #IsWorkspaceAdmin; // Caller must be admin of specified workspace
    #IsWorkspaceMember; // Caller must be member of specified workspace
  };

  public type AuthContext = {
    caller : Principal;
    workspaceId : ?Nat;
    orgOwner : Principal;
    orgAdmins : [Principal];
    workspaceAdmins : Map.Map<Nat, [Principal]>;
    workspaceMembers : Map.Map<Nat, [Principal]>;
  };

  // ============================================
  // Main Authorize Function
  // ============================================

  /// Authorizes a caller against a list of auth steps.
  /// Always checks for anonymous caller first (universal guard).
  /// Returns #ok(()) if any step passes (OR logic), or #err(concatenated messages) if all fail.
  public func authorize(
    ctx : AuthContext,
    steps : [AuthStep],
  ) : Result.Result<(), Text> {
    // Required steps missing. Alert developer with a trap.
    assert steps.size() > 0;

    // Universal: always check anonymous first
    if (Principal.isAnonymous(ctx.caller)) {
      return #err("Please login before calling this function.");
    };

    // Collect all error messages
    var errorMessages : [Text] = [];
    for (step in steps.vals()) {
      switch (checkStep(ctx, step)) {
        case (#ok(())) {
          // At least one step passed - return success immediately (OR logic)
          return #ok(());
        };
        case (#err(msg)) {
          // Add to array if not already present
          if (not arrayContains(errorMessages, msg)) {
            errorMessages := Array.concat(errorMessages, [msg]);
          };
        };
      };
    };

    // All steps failed - format the error
    #err(formatErrors(errorMessages));
  };

  // ============================================
  // Step Implementations
  // ============================================

  private func checkStep(ctx : AuthContext, step : AuthStep) : Result.Result<(), Text> {
    switch (step) {
      case (#IsOrgOwner) { checkIsOrgOwner(ctx) };
      case (#IsOrgAdmin) { checkIsOrgAdmin(ctx) };
      case (#AnyWorkspaceAdmin) { checkIsAnyWorkspaceAdmin(ctx) };
      case (#IsWorkspaceAdmin) { checkIsWorkspaceAdmin(ctx) };
      case (#IsWorkspaceMember) { checkIsWorkspaceMember(ctx) };
    };
  };

  private func checkIsOrgOwner(ctx : AuthContext) : Result.Result<(), Text> {
    if (ctx.caller == ctx.orgOwner) { #ok(()) } else {
      #err("Only org owner can perform this action.");
    };
  };

  private func checkIsOrgAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    if (isInList(ctx.caller, ctx.orgAdmins)) { #ok(()) } else {
      #err("Only org admins can perform this action.");
    };
  };

  private func checkIsAnyWorkspaceAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    // Check if caller is admin of ANY workspace
    for ((_, admins) in Map.entries(ctx.workspaceAdmins)) {
      if (isInList(ctx.caller, admins)) {
        return #ok(());
      };
    };
    #err("Only workspace admins can perform this action.");
  };

  private func checkIsWorkspaceAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    switch (ctx.workspaceId) {
      case (null) { #err("Workspace ID is required.") };
      case (?wsId) {
        switch (Map.get(ctx.workspaceAdmins, Nat.compare, wsId)) {
          case (null) { #err("Workspace not found.") };
          case (?admins) {
            if (isInList(ctx.caller, admins)) { #ok(()) } else {
              #err("Only workspace admins can perform this action.");
            };
          };
        };
      };
    };
  };

  private func checkIsWorkspaceMember(ctx : AuthContext) : Result.Result<(), Text> {
    switch (ctx.workspaceId) {
      case (null) { #err("Workspace ID is required.") };
      case (?wsId) {
        switch (Map.get(ctx.workspaceMembers, Nat.compare, wsId)) {
          case (null) { #err("Workspace not found.") };
          case (?members) {
            if (isInList(ctx.caller, members)) { #ok(()) } else {
              #err("Only workspace members can perform this action.");
            };
          };
        };
      };
    };
  };

  // ============================================
  // Helpers
  // ============================================

  func isInList(principal : Principal, list : [Principal]) : Bool {
    for (p in list.vals()) {
      if (p == principal) { return true };
    };
    false;
  };

  func arrayContains(arr : [Text], text : Text) : Bool {
    for (item in arr.vals()) {
      if (item == text) { return true };
    };
    false;
  };

  /// Formats a list of error messages, consolidating role-based errors into a single message
  func formatErrors(errors : [Text]) : Text {
    // Try to extract roles from known patterns and collect non-matching errors
    var roles : [Text] = [];
    var otherErrors : [Text] = [];

    for (error in errors.vals()) {
      let role = switch (error) {
        case ("Only org owner can perform this action.") { ?"org owner" };
        case ("Only org admins can perform this action.") { ?"org admins" };
        case ("Only workspace admins can perform this action.") {
          ?"workspace admins";
        };
        case ("Only workspace members can perform this action.") {
          ?"workspace members";
        };
        case (_) { null };
      };

      switch (role) {
        case (?r) {
          roles := Array.concat(roles, [r]);
        };
        case (null) {
          otherErrors := Array.concat(otherErrors, [error]);
        };
      };
    };

    // Build final error message
    var result = "";

    // Add consolidated role message if any roles were found
    if (roles.size() > 0) {
      result := "Only ";
      for (i in roles.keys()) {
        if (i > 0) {
          result #= ", ";
        };
        result #= roles[i];
      };
      result #= " can perform this action.";
    };

    // Add other errors with space separation
    for (error in otherErrors.vals()) {
      if (result != "") {
        result #= " ";
      };
      result #= error;
    };

    result;
  };
};
