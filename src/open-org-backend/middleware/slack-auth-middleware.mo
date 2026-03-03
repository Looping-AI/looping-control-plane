/// Slack Auth Middleware
///
/// Identity is established by looking up a Slack user ID in the SlackUserCache.
/// The resulting `UserAuthContext` is the single authorization token that all
/// downstream services and orchestrators accept instead of a caller Principal.
///
/// `roundCount` and `forceTerminated` are included here (see Phase 2.4) so that
/// the context is the single carrier of both identity and round-control state.
/// For Phase 0 they are always initialized to zero / false by `buildFromCache`.

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
  ///
  /// `roundCount` and `forceTerminated` support Phase 1.5 agent round control.
  /// `parentRef` records the channelId+ts of the message that triggered this context;
  ///   null means this is a round-0 context from an original user message.
  ///
  /// Invariant: `parentRef == null ↔ roundCount == 0`.
  ///   Following the chain: fetch `parentRef` → ConversationMessage → userAuthContext → repeat.
  ///   Chain terminates when `parentRef == null`.
  public type UserAuthContext = {
    slackUserId : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    workspaceScopes : Map.Map<Nat, SlackUserModel.WorkspaceScope>;
    roundCount : Nat;
    forceTerminated : Bool;
    parentRef : ?{ channelId : Text; ts : Text }; // null = round 0 (original user message)
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
    #IsWorkspaceMember : Nat; // User must be a member (any scope) of the given workspace ID
  };

  // ============================================
  // Constructors
  // ============================================

  /// Build a `UserAuthContext` from the Slack user cache.
  ///
  /// Returns `null` if `slackUserId` is not found in the cache. Callers should
  /// treat an absent user as unauthorized (equivalent to anonymous).
  ///
  /// `roundCount` and `forceTerminated` are seeded to their zero-values here.
  /// `parentRef` is always `null` for round-0 contexts (original user messages).
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
          roundCount = 0;
          forceTerminated = false;
          parentRef = null;
        };
      };
    };
  };

  /// Return a new `UserAuthContext` with updated round-control fields.
  ///
  /// `parentRef` must be supplied as `?{ channelId; ts }` pointing to the
  /// message that triggered this agent hop; pass `null` only for round-0 contexts
  /// (which callers should create via `buildFromCache` instead).
  ///
  /// Call site pattern:
  ///   `withRound(parentCtx, newRound, false, ?{ channelId = msg.channel; ts = msg.ts })`
  public func withRound(
    ctx : UserAuthContext,
    roundCount : Nat,
    forceTerminated : Bool,
    parentRef : ?{ channelId : Text; ts : Text },
  ) : UserAuthContext {
    {
      slackUserId = ctx.slackUserId;
      isPrimaryOwner = ctx.isPrimaryOwner;
      isOrgAdmin = ctx.isOrgAdmin;
      workspaceScopes = ctx.workspaceScopes;
      roundCount;
      forceTerminated;
      parentRef;
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
      case (#IsWorkspaceMember(wsId)) { checkIsWorkspaceMember(ctx, wsId) };
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
      case (?#member) {
        #err("Only workspace admins of workspace " # debug_show (workspaceId) # " can perform this action.");
      };
    };
  };

  private func checkIsWorkspaceMember(ctx : UserAuthContext, workspaceId : Nat) : Result.Result<(), Text> {
    switch (Map.get(ctx.workspaceScopes, Nat.compare, workspaceId)) {
      case (null) {
        #err("Only workspace members of workspace " # debug_show (workspaceId) # " can perform this action.");
      };
      case (?_) { #ok(()) }; // both #admin and #member satisfy membership
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
    var workspaceErrors : Map.Map<Nat, [Text]> = Map.empty<Nat, [Text]>();
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
    let memberPattern = "Only workspace members of workspace ";
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
    } else if (Text.startsWith(error, #text memberPattern)) {
      let afterRole = Text.replace(error, #text memberPattern, "");
      let wsIdStr = Text.replace(afterRole, #text suffix, "");
      switch (Int.fromText(wsIdStr)) {
        case (null) { null };
        case (?wsId) {
          if (wsId >= 0) { ?("members", Int.toNat(wsId)) } else {
            null;
          };
        };
      };
    } else {
      null;
    };
  };
};
