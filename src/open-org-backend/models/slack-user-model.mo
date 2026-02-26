import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Array "mo:core/Array";
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

  /// Internal per-workspace flags tracking which channel anchors a user is a member of.
  ///
  /// Storing both flags separately (rather than a single WorkspaceScope) lets the
  /// leave-channel handler correctly downgrade scope instead of blindly removing the
  /// workspace membership:
  ///   - leave admin channel while still in member channel → #admin drops to #member
  ///   - leave member channel while still in admin channel → scope stays #admin
  ///   - leave the only channel they were in → membership removed entirely
  public type WorkspaceChannelFlags = {
    inAdminChannel : Bool;
    inMemberChannel : Bool;
  };

  /// A cached Slack user with their resolved org-level roles and workspace memberships.
  ///
  /// `workspaceMemberships` maps each workspace the user belongs to → per-channel flags.
  /// Only workspaces where the user has an explicit membership are present.
  public type SlackUserEntry = {
    slackUserId : Text;
    displayName : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    workspaceMemberships : Map.Map<Nat, WorkspaceChannelFlags>;
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
      workspaceMemberships = Map.empty<Nat, WorkspaceChannelFlags>();
    };
  };

  // ============================================
  // Private Helpers
  // ============================================

  /// Derive the observable WorkspaceScope from per-channel flags.
  /// Returns null when the user is in neither channel (entry should be removed).
  private func scopeFromFlags(flags : WorkspaceChannelFlags) : ?WorkspaceScope {
    if (flags.inAdminChannel) { ?#admin } else if (flags.inMemberChannel) {
      ?#member;
    } else { null };
  };

  /// Read the existing channel flags for a workspace, defaulting to both-false.
  private func getOrInitFlags(entry : SlackUserEntry, workspaceId : Nat) : WorkspaceChannelFlags {
    switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
      case (?flags) { flags };
      case (null) { { inAdminChannel = false; inMemberChannel = false } };
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
  // CRUD — Workspace Memberships (channel-level)
  // ============================================

  /// Record that a user has joined the admin-channel anchor of a workspace.
  ///
  /// Sets `inAdminChannel = true` without touching `inMemberChannel`.
  /// Returns #err if the user is not found in the cache.
  public func joinAdminChannel(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Result.Result<(), Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        let current = getOrInitFlags(entry, workspaceId);
        let updated : WorkspaceChannelFlags = {
          inAdminChannel = true;
          inMemberChannel = current.inMemberChannel;
        };
        Map.add(entry.workspaceMemberships, Nat.compare, workspaceId, updated);
        #ok(());
      };
    };
  };

  /// Record that a user has joined the member-channel anchor of a workspace.
  ///
  /// Sets `inMemberChannel = true` without touching `inAdminChannel`.
  /// Returns #err if the user is not found in the cache.
  public func joinMemberChannel(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Result.Result<(), Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        let current = getOrInitFlags(entry, workspaceId);
        let updated : WorkspaceChannelFlags = {
          inAdminChannel = current.inAdminChannel;
          inMemberChannel = true;
        };
        Map.add(entry.workspaceMemberships, Nat.compare, workspaceId, updated);
        #ok(());
      };
    };
  };

  /// Record that a user has left the admin-channel anchor of a workspace.
  ///
  /// Clears `inAdminChannel`. If `inMemberChannel` is also false the workspace
  /// membership entry is removed entirely (user is no longer in any channel).
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the flag was already clear; #ok(true) if it was cleared.
  public func leaveAdminChannel(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
          case (null) { #ok(false) };
          case (?flags) {
            if (not flags.inAdminChannel) { #ok(false) } else {
              let updated : WorkspaceChannelFlags = {
                inAdminChannel = false;
                inMemberChannel = flags.inMemberChannel;
              };
              if (not updated.inAdminChannel and not updated.inMemberChannel) {
                Map.remove(entry.workspaceMemberships, Nat.compare, workspaceId);
              } else {
                Map.add(entry.workspaceMemberships, Nat.compare, workspaceId, updated);
              };
              #ok(true);
            };
          };
        };
      };
    };
  };

  /// Record that a user has left the member-channel anchor of a workspace.
  ///
  /// Clears `inMemberChannel`. If `inAdminChannel` is also false the workspace
  /// membership entry is removed entirely.
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the flag was already clear; #ok(true) if it was cleared.
  public func leaveMemberChannel(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
          case (null) { #ok(false) };
          case (?flags) {
            if (not flags.inMemberChannel) { #ok(false) } else {
              let updated : WorkspaceChannelFlags = {
                inAdminChannel = flags.inAdminChannel;
                inMemberChannel = false;
              };
              if (not updated.inAdminChannel and not updated.inMemberChannel) {
                Map.remove(entry.workspaceMemberships, Nat.compare, workspaceId);
              } else {
                Map.add(entry.workspaceMemberships, Nat.compare, workspaceId, updated);
              };
              #ok(true);
            };
          };
        };
      };
    };
  };

  // ============================================
  // Query Helpers
  // ============================================

  /// Return the workspace memberships of an entry as an array of (workspaceId, scope) tuples.
  /// Entries where both channel flags are false are excluded (should not normally exist).
  public func getWorkspaceMemberships(entry : SlackUserEntry) : [WorkspaceMembership] {
    Array.filterMap<(Nat, WorkspaceChannelFlags), WorkspaceMembership>(
      Iter.toArray(Map.entries(entry.workspaceMemberships)),
      func((wsId, flags)) {
        switch (scopeFromFlags(flags)) {
          case (?scope) { ?(wsId, scope) };
          case (null) { null };
        };
      },
    );
  };

  /// Build a `Map<workspaceId, WorkspaceScope>` from a user entry suitable for
  /// embedding in a `UserAuthContext`.  Only workspaces with an active membership
  /// (at least one channel flag set) are included.
  public func buildWorkspaceScopeMap(entry : SlackUserEntry) : Map.Map<Nat, WorkspaceScope> {
    let scopeMap = Map.empty<Nat, WorkspaceScope>();
    for ((wsId, flags) in Map.entries(entry.workspaceMemberships)) {
      switch (scopeFromFlags(flags)) {
        case (?scope) { Map.add(scopeMap, Nat.compare, wsId, scope) };
        case (null) {};
      };
    };
    scopeMap;
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
        switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
          case (null) { null };
          case (?flags) { scopeFromFlags(flags) };
        };
      };
    };
  };
};
