import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";

module {
  // ============================================
  // Types
  // ============================================

  public type AuthStep = {
    #IsOrgOwner; // Caller must be the org owner
    #IsOrgAdmin; // Caller must be an org admin
    #IsWorkspaceAdmin; // Caller must be admin of specified workspace
    #IsWorkspaceMember; // Caller must be member of specified workspace
    #HasWorkspaceAccess; // Caller is admin OR member of workspace
    #IsOrgOwnerOrWsAdmin; // Caller is org owner OR workspace admin
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
  /// Returns #ok(()) if all steps pass, or #err(message) on first failure.
  public func authorize(
    ctx : AuthContext,
    steps : [AuthStep],
  ) : Result.Result<(), Text> {
    // Universal: always check anonymous first
    if (Principal.isAnonymous(ctx.caller)) {
      return #err("Please login before calling this function");
    };

    // Run each step in order, fail fast on first error
    for (step in steps.vals()) {
      switch (checkStep(ctx, step)) {
        case (#err(msg)) { return #err(msg) };
        case (#ok(())) {};
      };
    };
    #ok(());
  };

  // ============================================
  // Step Implementations
  // ============================================

  private func checkStep(ctx : AuthContext, step : AuthStep) : Result.Result<(), Text> {
    switch (step) {
      case (#IsOrgOwner) { checkIsOrgOwner(ctx) };
      case (#IsOrgAdmin) { checkIsOrgAdmin(ctx) };
      case (#IsWorkspaceAdmin) { checkIsWorkspaceAdmin(ctx) };
      case (#IsWorkspaceMember) { checkIsWorkspaceMember(ctx) };
      case (#HasWorkspaceAccess) { checkHasWorkspaceAccess(ctx) };
      case (#IsOrgOwnerOrWsAdmin) { checkIsOrgOwnerOrWsAdmin(ctx) };
    };
  };

  private func checkIsOrgOwner(ctx : AuthContext) : Result.Result<(), Text> {
    if (ctx.caller == ctx.orgOwner) { #ok(()) } else {
      #err("Only the owner can perform this action");
    };
  };

  private func checkIsOrgAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    if (isInList(ctx.caller, ctx.orgAdmins)) { #ok(()) } else {
      #err("Only org admins can perform this action");
    };
  };

  private func checkIsWorkspaceAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    switch (ctx.workspaceId) {
      case (null) { #err("Workspace ID is required") };
      case (?wsId) {
        switch (Map.get(ctx.workspaceAdmins, Nat.compare, wsId)) {
          case (null) { #err("Workspace not found") };
          case (?admins) {
            if (isInList(ctx.caller, admins)) { #ok(()) } else {
              #err("Only workspace admins can perform this action");
            };
          };
        };
      };
    };
  };

  private func checkIsWorkspaceMember(ctx : AuthContext) : Result.Result<(), Text> {
    switch (ctx.workspaceId) {
      case (null) { #err("Workspace ID is required") };
      case (?wsId) {
        switch (Map.get(ctx.workspaceMembers, Nat.compare, wsId)) {
          case (null) { #err("Workspace not found") };
          case (?members) {
            if (isInList(ctx.caller, members)) { #ok(()) } else {
              #err("Only workspace members can perform this action");
            };
          };
        };
      };
    };
  };

  private func checkHasWorkspaceAccess(ctx : AuthContext) : Result.Result<(), Text> {
    switch (ctx.workspaceId) {
      case (null) { #err("Workspace ID is required") };
      case (?wsId) {
        // Check workspace exists via admins map
        switch (Map.get(ctx.workspaceAdmins, Nat.compare, wsId)) {
          case (null) { #err("Workspace not found") };
          case (?admins) {
            if (isInList(ctx.caller, admins)) {
              return #ok(());
            };
            // Not admin, check if member
            switch (Map.get(ctx.workspaceMembers, Nat.compare, wsId)) {
              case (null) { #err("Workspace not found") };
              case (?members) {
                if (isInList(ctx.caller, members)) { #ok(()) } else {
                  #err("You are not an admin or member of this workspace");
                };
              };
            };
          };
        };
      };
    };
  };

  private func checkIsOrgOwnerOrWsAdmin(ctx : AuthContext) : Result.Result<(), Text> {
    // First check if org owner
    if (ctx.caller == ctx.orgOwner) {
      return #ok(());
    };
    // Otherwise must be workspace admin
    checkIsWorkspaceAdmin(ctx);
  };

  // ============================================
  // Helpers
  // ============================================

  private func isInList(principal : Principal, list : [Principal]) : Bool {
    for (p in list.vals()) {
      if (p == principal) { return true };
    };
    false;
  };
};
