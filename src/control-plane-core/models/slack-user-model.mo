import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import List "mo:core/List";
import Time "mo:core/Time";

module {
  // ============================================
  // Types
  // ============================================

  /// A cached Slack user with their resolved org-level roles and workspace admin memberships.
  ///
  /// `adminWorkspaces` is a set of workspace IDs where the user is an admin
  /// (derived from Slack admin-channel membership). Presence in the set ≡ is admin.
  public type SlackUserEntry = {
    slackUserId : Text;
    displayName : Text;
    isPrimaryOwner : Bool;
    isOrgAdmin : Bool;
    isBot : Bool;
    adminWorkspaces : Map.Map<Nat, ()>;
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
      adminWorkspaces = Map.empty<Nat, ()>();
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

  // (No private helpers needed — admin workspace set uses direct Map operations.)

  // ============================================
  // CRUD — Users
  // ============================================

  /// Insert or fully replace a user in the cache, logging any access-level changes.
  ///
  /// - New user: logs #userAdded, plus #orgAdminGranted / #primaryOwnerGranted if applicable.
  /// - Existing user: logs #orgAdminGranted/Revoked and #primaryOwnerGranted/Revoked only
  ///   when the corresponding flags actually change.
  ///
  /// Workspace admin memberships are NOT touched here; callers doing a profile-only refresh
  /// must pass back the existing `adminWorkspaces` from the current entry.
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
  /// Adds the workspace to the user's `adminWorkspaces` set.
  /// Logs #workspaceAdminGranted(workspaceId) only when the workspace was not already present.
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
        let wasAdmin = Map.containsKey(entry.adminWorkspaces, Nat.compare, workspaceId);
        if (not wasAdmin) {
          logChange(state.changeLog, slackUserId, #workspaceAdminGranted(workspaceId), source);
        };
        Map.add(entry.adminWorkspaces, Nat.compare, workspaceId, ());
        #ok(());
      };
    };
  };

  /// Record that a user has left the admin-channel anchor of a workspace.
  ///
  /// Removes the workspace from the user's `adminWorkspaces` set.
  /// Logs #workspaceAdminRevoked(workspaceId) when the workspace was actually removed.
  /// Returns #err if the user is not in the cache.
  /// Returns #ok(false) if the workspace was not in the set; #ok(true) if it was removed.
  public func leaveAdminChannel(
    state : SlackUserState,
    slackUserId : Text,
    workspaceId : Nat,
    source : AccessChangeSource,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.cache, Text.compare, slackUserId)) {
      case (null) { #err("User not found: " # slackUserId) };
      case (?entry) {
        if (not Map.containsKey(entry.adminWorkspaces, Nat.compare, workspaceId)) {
          #ok(false);
        } else {
          Map.remove(entry.adminWorkspaces, Nat.compare, workspaceId);
          logChange(state.changeLog, slackUserId, #workspaceAdminRevoked(workspaceId), source);
          #ok(true);
        };
      };
    };
  };

  // ============================================
  // Query Helpers
  // ============================================

  /// Return the IDs of workspaces where the user is an admin.
  public func getAdminWorkspaceIds(entry : SlackUserEntry) : [Nat] {
    Iter.toArray(Map.keys(entry.adminWorkspaces));
  };

  /// Check whether a user is an admin of a specific workspace.
  /// Returns false if the user is not found or has no admin membership in that workspace.
  public func isWorkspaceAdmin(
    cache : SlackUserCache,
    slackUserId : Text,
    workspaceId : Nat,
  ) : Bool {
    switch (Map.get(cache, Text.compare, slackUserId)) {
      case (null) { false };
      case (?entry) {
        Map.containsKey(entry.adminWorkspaces, Nat.compare, workspaceId);
      };
    };
  };
};
