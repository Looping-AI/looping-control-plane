import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Array "mo:core/Array";
import Result "mo:core/Result";
import List "mo:core/List";
import Time "mo:core/Time";

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
    isBot : Bool;
    workspaceMemberships : Map.Map<Nat, WorkspaceChannelFlags>;
  };

  /// The full Slack user cache: Slack user ID → SlackUserEntry.
  public type SlackUserCache = Map.Map<Text, SlackUserEntry>;

  // ============================================
  // Access Change Log Types
  // ============================================

  /// The origin of an access change — allows auditors to distinguish reconciliation
  /// corrections from real-time Slack events.
  public type AccessChangeSource = {
    #reconciliation;
    #slackEvent : Text; // carries the Slack event ID
    #manual;
  };

  /// The kind of access mutation that occurred.
  public type AccessChangeType = {
    #userAdded;
    #userRemoved;
    #orgAdminGranted;
    #orgAdminRevoked;
    #primaryOwnerGranted;
    #primaryOwnerRevoked;
    #workspaceAdminGranted : Nat; // workspaceId
    #workspaceAdminRevoked : Nat; // workspaceId
    #workspaceMemberGranted : Nat; // workspaceId
    #workspaceMemberRevoked : Nat; // workspaceId
  };

  /// A single entry in the access change log.
  public type AccessChangeEntry = {
    slackUserId : Text;
    changeType : AccessChangeType;
    source : AccessChangeSource;
    timestamp : Int;
  };

  /// Mutable, append-only access change log.
  /// Oldest entries are at the start (index 0); newest entries are appended at the end.
  /// Uses `mo:core/List` — a mutable growable array with O(1) append.
  public type AccessChangeLog = List.List<AccessChangeEntry>;

  /// Combined state record: the user cache and its access change log.
  /// All mutation functions that change access-related fields should operate on this
  /// state so that every change is automatically audit-logged.
  ///
  /// `cache` is a mutable Map (reference semantics — mutations propagate automatically).
  /// `changeLog` is a `var` field so that `purgeOldLogs` can reassign it to a
  /// filtered copy without reconstructing the entire state.
  public type SlackUserState = {
    cache : SlackUserCache;
    var changeLog : AccessChangeLog;
  };

  // ============================================
  // Constructors
  // ============================================

  /// Create an empty Slack user cache.
  public func empty() : SlackUserCache {
    Map.empty<Text, SlackUserEntry>();
  };

  /// Create an empty SlackUserState (cache + change log).
  public func emptyState() : SlackUserState {
    {
      cache = Map.empty<Text, SlackUserEntry>();
      var changeLog = List.empty<AccessChangeEntry>();
    };
  };

  /// Construct a new SlackUserEntry with no workspace memberships.
  public func newEntry(
    slackUserId : Text,
    displayName : Text,
    isPrimaryOwner : Bool,
    isOrgAdmin : Bool,
    isBot : Bool,
  ) : SlackUserEntry {
    {
      slackUserId;
      displayName;
      isPrimaryOwner;
      isOrgAdmin;
      isBot;
      workspaceMemberships = Map.empty<Nat, WorkspaceChannelFlags>();
    };
  };

  // ============================================
  // Access Change Log Helpers
  // ============================================

  /// Append an entry to the access change log (newest at end).
  /// Private helper used by mutation functions to ensure all access changes are logged consistently.
  private func logChange(
    log : AccessChangeLog,
    slackUserId : Text,
    changeType : AccessChangeType,
    source : AccessChangeSource,
  ) {
    List.add(
      log,
      {
        slackUserId;
        changeType;
        source;
        timestamp = Time.now();
      },
    );
  };

  /// Remove all log entries older than `retentionNs` nanoseconds from now.
  /// Reassigns `state.changeLog` to a new filtered list.
  /// Returns the number of entries purged.
  public func purgeOldLogs(state : SlackUserState, retentionNs : Nat) : Nat {
    let cutoff : Int = Time.now() - retentionNs;
    // Count purged entries during the filter itself to avoid Nat-subtraction warnings.
    var purged : Nat = 0;
    let kept = List.filter<AccessChangeEntry>(
      state.changeLog,
      func(e) {
        if (e.timestamp >= cutoff) { true } else { purged += 1; false };
      },
    );
    if (purged > 0) {
      state.changeLog := kept;
    };
    purged;
  };

  /// Return log entries since a given timestamp (inclusive), as an array.
  /// Useful for querying what changed during a reconciliation run.
  public func getLogsSince(state : SlackUserState, since : Int) : [AccessChangeEntry] {
    List.toArray(
      List.filter<AccessChangeEntry>(
        state.changeLog,
        func(entry) { entry.timestamp >= since },
      )
    );
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

  /// Insert or fully replace a user in the cache, logging any access-level changes.
  ///
  /// - New user: logs #userAdded, plus #orgAdminGranted / #primaryOwnerGranted if applicable.
  /// - Existing user: logs #orgAdminGranted/Revoked and #primaryOwnerGranted/Revoked only
  ///   when the corresponding flags actually change.
  ///
  /// Workspace memberships are NOT touched here; callers doing a profile-only refresh
  /// must pass back the existing `workspaceMemberships` from the current entry.
  public func upsertUser(state : SlackUserState, entry : SlackUserEntry, source : AccessChangeSource) {
    switch (Map.get(state.cache, Text.compare, entry.slackUserId)) {
      case (null) {
        // Brand-new user
        logChange(state.changeLog, entry.slackUserId, #userAdded, source);
        if (entry.isOrgAdmin) {
          logChange(state.changeLog, entry.slackUserId, #orgAdminGranted, source);
        };
        if (entry.isPrimaryOwner) {
          logChange(state.changeLog, entry.slackUserId, #primaryOwnerGranted, source);
        };
      };
      case (?existing) {
        // Existing user — log any access-level transitions
        if (not existing.isOrgAdmin and entry.isOrgAdmin) {
          logChange(state.changeLog, entry.slackUserId, #orgAdminGranted, source);
        } else if (existing.isOrgAdmin and not entry.isOrgAdmin) {
          logChange(state.changeLog, entry.slackUserId, #orgAdminRevoked, source);
        };
        if (not existing.isPrimaryOwner and entry.isPrimaryOwner) {
          logChange(state.changeLog, entry.slackUserId, #primaryOwnerGranted, source);
        } else if (existing.isPrimaryOwner and not entry.isPrimaryOwner) {
          logChange(state.changeLog, entry.slackUserId, #primaryOwnerRevoked, source);
        };
      };
    };
    Map.add(state.cache, Text.compare, entry.slackUserId, entry);
  };

  /// Look up a user by their Slack user ID. Returns null if not found.
  public func lookupUser(cache : SlackUserCache, slackUserId : Text) : ?SlackUserEntry {
    Map.get(cache, Text.compare, slackUserId);
  };

  /// Remove a user and all of their workspace memberships from the cache.
  /// Logs #userRemoved when the user was actually present.
  /// Returns true if the user was present; false if no-op.
  public func removeUser(state : SlackUserState, slackUserId : Text, source : AccessChangeSource) : Bool {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
      case (null) { false };
      case (?_) {
        logChange(state.changeLog, slackUserId, #userRemoved, source);
        Map.remove(state.cache, Text.compare, slackUserId);
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
  /// Logs #workspaceAdminGranted(workspaceId) only when the flag was previously clear.
  /// Returns #err if the user is not found in the cache.
  public func joinAdminChannel(
    state : SlackUserState,
    slackUserId : Text,
    workspaceId : Nat,
    source : AccessChangeSource,
  ) : Result.Result<(), Text> {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        let current = getOrInitFlags(entry, workspaceId);
        if (not current.inAdminChannel) {
          logChange(state.changeLog, slackUserId, #workspaceAdminGranted(workspaceId), source);
        };
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
  /// Logs #workspaceMemberGranted(workspaceId) only when the flag was previously clear.
  /// Returns #err if the user is not found in the cache.
  public func joinMemberChannel(
    state : SlackUserState,
    slackUserId : Text,
    workspaceId : Nat,
    source : AccessChangeSource,
  ) : Result.Result<(), Text> {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        let current = getOrInitFlags(entry, workspaceId);
        if (not current.inMemberChannel) {
          logChange(state.changeLog, slackUserId, #workspaceMemberGranted(workspaceId), source);
        };
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
  /// Logs #workspaceAdminRevoked(workspaceId) when the flag was actually cleared.
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the flag was already clear; #ok(true) if it was cleared.
  public func leaveAdminChannel(
    state : SlackUserState,
    slackUserId : Text,
    workspaceId : Nat,
    source : AccessChangeSource,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
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
              logChange(state.changeLog, slackUserId, #workspaceAdminRevoked(workspaceId), source);
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
  /// Logs #workspaceMemberRevoked(workspaceId) when the flag was actually cleared.
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the flag was already clear; #ok(true) if it was cleared.
  public func leaveMemberChannel(
    state : SlackUserState,
    slackUserId : Text,
    workspaceId : Nat,
    source : AccessChangeSource,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
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
              logChange(state.changeLog, slackUserId, #workspaceMemberRevoked(workspaceId), source);
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
