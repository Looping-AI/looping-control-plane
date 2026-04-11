/// Slack Auth Middleware
///
/// Identity is established by looking up a Slack user ID in the SlackUserCache.
/// The resulting `UserAuthContext` is the single authorization token that all
/// downstream services and orchestrators accept instead of a caller Principal.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Array "mo:core/Array";
import Int "mo:core/Int";
import SlackUserModel "../models/slack-user-model";

module {

  // ============================================
  // Types
  // ============================================

  /// Authorization context built from the Slack user cache.
  /// Passed to all downstream services instead of a caller Principal.
  ///
  /// `workspaceScopes` contains only the workspaces the user explicitly belongs to.
  /// A missing workspace ID means the user has no access to that workspace.
  public type UserAuthContext = {
    slackUserId : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    workspaceScopes : Map.Map<Nat, SlackUserModel.WorkspaceScope>;
  };

  /// Authorization step — describes a single access requirement.
  /// `authorize` uses OR logic: the check passes as soon as any one step succeeds.
  ///
  /// Steps that require a specific workspace carry the workspace ID inline so
  /// the middleware can look it up in `workspaceScopes` without extra parameters.
  public type AuthStep = {
    #IsPrimaryOwner; // User must be the Slack workspace's Primary Owner
    #IsOrgAdmin; // User must be flagged as org admin (isPrimaryOwner or isOrgAdmin)
    #IsWorkspaceAdmin : Nat; // User must be admin of the given workspace ID
  };

  // ============================================
  // Constructors
  // ============================================

  /// Build a `UserAuthContext` from the Slack user cache.
  ///
  /// Returns `null` if `slackUserId` is not found in the cache. Callers should
  /// treat an absent user as unauthorized (equivalent to anonymous).
  public func buildFromCache(
    slackUserId : Text,
    cache : SlackUserModel.SlackUserCache,
  ) : ?UserAuthContext {
    switch (SlackUserModel.lookupUser(cache, slackUserId)) {
      case (null) { null };
      case (?entry) {
        ?{
          slackUserId = entry.slackUserId;
          isPrimaryOwner = entry.isPrimaryOwner;
          isOrgAdmin = entry.isOrgAdmin;
          workspaceScopes = SlackUserModel.buildWorkspaceScopeMap(entry);
        };
      };
    };
  };

  // ============================================
  // Authorization
  // ============================================

  /// Authorize a `UserAuthContext` against one or more `AuthStep`s.
  ///
  /// Logic is identical to the old `AuthMiddleware.authorize`:
  ///   - Steps are evaluated with OR semantics — first passing step returns `#ok`.
  ///   - All steps must have been supplied (traps if empty — developer error).
  ///   - Returns `#err` with all collected failure messages if every step fails.
  public func authorize(
    ctx : UserAuthContext,
    steps : [AuthStep],
  ) : Result.Result<(), Text> {
    assert steps.size() > 0;

    var errorMessages : [Text] = [];
    for (step in steps.vals()) {
      switch (checkStep(ctx, step)) {
        case (#ok(())) { return #ok(()) };
        case (#err(msg)) {
          if (not arrayContains(errorMessages, msg)) {
            errorMessages := Array.concat(errorMessages, [msg]);
          };
        };
      };
    };

    #err(formatErrors(errorMessages));
  };

  // ============================================
  // Step Implementations (private)
  // ============================================

  private func checkStep(ctx : UserAuthContext, step : AuthStep) : Result.Result<(), Text> {
    switch (step) {
      case (#IsPrimaryOwner) { checkIsPrimaryOwner(ctx) };
      case (#IsOrgAdmin) { checkIsOrgAdmin(ctx) };
      case (#IsWorkspaceAdmin(wsId)) { checkIsWorkspaceAdmin(ctx, wsId) };
    };
  };

  private func checkIsPrimaryOwner(ctx : UserAuthContext) : Result.Result<(), Text> {
    if (ctx.isPrimaryOwner) { #ok(()) } else {
      #err("Only the Primary Owner can perform this action.");
    };
  };

  private func checkIsOrgAdmin(ctx : UserAuthContext) : Result.Result<(), Text> {
    if (ctx.isPrimaryOwner or ctx.isOrgAdmin) { #ok(()) } else {
      #err("Only org admins can perform this action.");
    };
  };

  private func checkIsWorkspaceAdmin(ctx : UserAuthContext, workspaceId : Nat) : Result.Result<(), Text> {
    switch (Map.get(ctx.workspaceScopes, Nat.compare, workspaceId)) {
      case (null) {
        #err("Only workspace admins of workspace " # debug_show (workspaceId) # " can perform this action.");
      };
      case (?#admin) { #ok(()) };
    };
  };

  // ============================================
  // Helpers (private)
  // ============================================

  private func arrayContains(arr : [Text], value : Text) : Bool {
    for (item in arr.vals()) {
      if (item == value) { return true };
    };
    false;
  };

  /// Formats a list of error messages, consolidating role-based errors into a single message.
  /// Extracts role information from known patterns and groups them with commas.
  /// For workspace-scoped errors, groups by workspace ID before consolidating.
  /// Other errors are appended separately.
  private func formatErrors(messages : [Text]) : Text {
    var roles : [Text] = [];
    let workspaceErrors : Map.Map<Nat, [Text]> = Map.empty<Nat, [Text]>();
    var otherErrors : [Text] = [];

    for (error in messages.vals()) {
      // Try to match org-level roles first
      let orgRole = switch (error) {
        case ("Only the Primary Owner can perform this action.") {
          ?"Primary Owner";
        };
        case ("Only org admins can perform this action.") { ?"org admins" };
        case (_) { null };
      };

      switch (orgRole) {
        case (?r) {
          roles := Array.concat(roles, [r]);
        };
        case (null) {
          // Try to match workspace-scoped errors
          let wsPattern = extractWorkspaceError(error);
          switch (wsPattern) {
            case (?(role, wsId)) {
              // Group by workspace ID
              let existing = switch (Map.get(workspaceErrors, Nat.compare, wsId)) {
                case (null) { [] };
                case (?arr) { arr };
              };
              Map.add(workspaceErrors, Nat.compare, wsId, Array.concat(existing, [role]));
            };
            case (null) {
              // Not a recognized pattern, keep as-is
              otherErrors := Array.concat(otherErrors, [error]);
            };
          };
        };
      };
    };

    // Build final error message
    var result = "";

    // Add consolidated org-level role message if any found
    if (roles.size() > 0) {
      result := "Only ";
      for (i in roles.keys()) {
        if (i > 0) {
          result #= " or ";
        };
        result #= roles[i];
      };
      result #= " can perform this action.";
    };

    // Add workspace-scoped errors, consolidated by workspace
    for ((wsId, roleList) in Map.entries(workspaceErrors)) {
      if (result != "") {
        result #= " ";
      };
      result #= "Only ";
      for (i in roleList.keys()) {
        if (i > 0) {
          result #= " or ";
        };
        result #= roleList[i];
      };
      result #= " of workspace " # debug_show (wsId) # " can perform this action.";
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

  /// Extract workspace error pattern from error message.
  /// Returns ?(role, workspaceId) if the message matches "Only {role} of workspace {id} can perform this action."
  private func extractWorkspaceError(error : Text) : ?(Text, Nat) {
    let adminPattern = "Only workspace admins of workspace ";
    let suffix = " can perform this action.";

    if (Text.startsWith(error, #text adminPattern)) {
      let afterRole = Text.replace(error, #text adminPattern, "");
      let wsIdStr = Text.replace(afterRole, #text suffix, "");
      switch (Int.fromText(wsIdStr)) {
        case (null) { null };
        case (?wsId) {
          if (wsId >= 0) { ?("admins", Int.toNat(wsId)) } else {
            null;
          };
        };
      };
    } else {
      null;
    };
  };
};
