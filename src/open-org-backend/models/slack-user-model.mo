import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Result "mo:core/Result";

module {
  // ============================================
  // Types
  // ============================================

  /// Access level a user has within a workspace.
  /// Derived from Slack channel membership: admin channel → #admin, member channel → #member.
  public type WorkspaceScope = {
    #admin;
    #member;
  };

  /// A (workspaceId, scope) pair for readable output (e.g. API responses, tests).
  public type WorkspaceMembership = (Nat, WorkspaceScope);

  /// A cached Slack user with their resolved org-level roles and workspace memberships.
  ///
  /// `workspaceMemberships` maps each workspace the user belongs to → their scope.
  /// Only workspaces where the user has an explicit membership are present.
  public type SlackUserEntry = {
    slackUserId : Text;
    displayName : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    workspaceMemberships : Map.Map<Nat, WorkspaceScope>;
  };

  /// The full Slack user cache: Slack user ID → SlackUserEntry.
  public type SlackUserCache = Map.Map<Text, SlackUserEntry>;

  // ============================================
  // Constructors
  // ============================================

  /// Create an empty Slack user cache.
  public func empty() : SlackUserCache {
    Map.empty<Text, SlackUserEntry>();
  };

  /// Construct a new SlackUserEntry with no workspace memberships.
  public func newEntry(
    slackUserId : Text,
    displayName : Text,
    isPrimaryOwner : Bool,
    isOrgAdmin : Bool,
  ) : SlackUserEntry {
    {
      slackUserId;
      displayName;
      isPrimaryOwner;
      isOrgAdmin;
      workspaceMemberships = Map.empty<Nat, WorkspaceScope>();
    };
  };

  // ============================================
  // CRUD — Users
  // ============================================

  /// Insert or fully replace a user in the cache.
  /// Existing entry (including all workspace memberships) will be overwritten.
  public func upsertUser(cache : SlackUserCache, entry : SlackUserEntry) {
    Map.add(cache, Text.compare, entry.slackUserId, entry);
  };

  /// Look up a user by their Slack user ID. Returns null if not found.
  public func lookupUser(cache : SlackUserCache, slackUserId : Text) : ?SlackUserEntry {
    Map.get(cache, Text.compare, slackUserId);
  };

  /// Remove a user and all of their workspace memberships from the cache.
  /// Returns true if the user was present; false if no-op.
  public func removeUser(cache : SlackUserCache, slackUserId : Text) : Bool {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { false };
      case (?_) {
        Map.remove(cache, Text.compare, slackUserId);
        true;
      };
    };
  };

  /// List all users currently in the cache.
  public func listUsers(cache : SlackUserCache) : [SlackUserEntry] {
    Iter.toArray(Map.values(cache));
  };

  // ============================================
  // CRUD — Workspace Memberships
  // ============================================

  /// Add or update the workspace scope for an existing user.
  /// Returns #err if the user is not found in the cache.
  public func updateWorkspaceMembership(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
    scope : WorkspaceScope,
  ) : Result.Result<(), Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        Map.add(entry.workspaceMemberships, Nat.compare, workspaceId, scope);
        #ok(());
      };
    };
  };

  /// Remove a workspace membership from a user.
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the membership did not exist; #ok(true) if it was removed.
  public func removeWorkspaceMembership(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
          case (null) { #ok(false) };
          case (?_) {
            Map.remove(entry.workspaceMemberships, Nat.compare, workspaceId);
            #ok(true);
          };
        };
      };
    };
  };

  // ============================================
  // Query Helpers
  // ============================================

  /// Return the workspace memberships of an entry as an array of (workspaceId, scope) tuples.
  public func getWorkspaceMemberships(entry : SlackUserEntry) : [WorkspaceMembership] {
    Iter.toArray(Map.entries(entry.workspaceMemberships));
  };

  /// Look up the scope a user has in a specific workspace.
  /// Returns null if the user is not found or has no membership in that workspace.
  public func getWorkspaceScope(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : ?WorkspaceScope {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { null };
      case (?entry) {
        Map.get(entry.workspaceMemberships, Nat.compare, workspaceId);
      };
    };
  };
};
