/// Workspace Model
/// Persistent workspace records with Slack channel anchors for admin and member channels.
///
/// A workspace record stores the channel IDs that determine membership:
///   - `adminChannelId`  — members of this Slack channel get `#admin` scope for the workspace
///   - `memberChannelId` — members of this Slack channel get `#member` scope for the workspace
///
/// Workspace 0 is the org workspace. Its `adminChannelId` doubles as the org-admin channel
/// anchor — members of that channel are treated as org-level admins. There is no separate
/// org-admin channel state; setting workspace 0's admin channel IS setting the org-admin
/// channel, and only the org owner is allowed to do so.
///
/// Membership itself is stored in the SlackUserCache (SlackUserModel); these channel anchors
/// are used by event handlers to resolve which workspace and scope to assign when Slack fires
/// `member_joined_channel` / `member_left_channel` events.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Text "mo:core/Text";

module {

  // ============================================
  // Types
  // ============================================

  /// A workspace record with Slack channel anchors.
  public type WorkspaceRecord = {
    id : Nat;
    name : Text;
    adminChannelId : ?Text; // Slack channel ID whose members become workspace admins
    memberChannelId : ?Text; // Slack channel ID whose members become workspace members
  };

  /// Mutable state for the workspace registry.
  public type WorkspacesState = {
    var nextId : Nat;
    workspaces : Map.Map<Nat, WorkspaceRecord>;
  };

  /// Result of resolving a Slack channel ID against all workspace anchors.
  ///
  /// #none              — channel not found in any workspace anchor
  /// #adminChannel(id)  — channel is the admin channel of workspace `id`
  /// #memberChannel(id) — channel is the member channel of workspace `id`
  public type ChannelResolution = {
    #none;
    #adminChannel : Nat;
    #memberChannel : Nat;
  };

  // ============================================
  // Constructors
  // ============================================

  /// Create an empty workspaces state.
  /// Pre-seeds workspace 0 ("Default") to mirror the default workspace that all other
  /// per-workspace maps start with in main.mo.
  public func emptyState() : WorkspacesState {
    let state : WorkspacesState = {
      var nextId = 1; // next ID after workspace 0 is 1
      workspaces = Map.empty<Nat, WorkspaceRecord>();
    };
    let defaultWorkspace : WorkspaceRecord = {
      id = 0;
      name = "Default";
      adminChannelId = null;
      memberChannelId = null;
    };
    Map.add(state.workspaces, Nat.compare, 0, defaultWorkspace);
    state;
  };

  // ============================================
  // CRUD — Workspaces
  // ============================================

  /// Create a new workspace. Returns the new workspace's ID.
  /// Returns `#err` if:
  ///   - name is empty
  ///   - a workspace with the same name already exists
  public func createWorkspace(state : WorkspacesState, name : Text) : Result.Result<Nat, Text> {
    if (Text.size(name) == 0) {
      return #err("Workspace name cannot be empty.");
    };

    // Check for duplicate names
    for ((_, existing) in Map.entries(state.workspaces)) {
      if (Text.equal(existing.name, name)) {
        return #err("A workspace with this name already exists.");
      };
    };

    let id = state.nextId;
    let record : WorkspaceRecord = {
      id;
      name;
      adminChannelId = null;
      memberChannelId = null;
    };
    Map.add(state.workspaces, Nat.compare, id, record);
    state.nextId += 1;
    #ok(id);
  };

  /// List all workspaces.
  public func listWorkspaces(state : WorkspacesState) : [WorkspaceRecord] {
    Iter.toArray(Map.values(state.workspaces));
  };

  // ============================================
  // Channel Anchor Management
  // ============================================

  /// Guard: verify that `channelId` is not already in use by any anchor except the slot
  /// being replaced (`excludedSlot` of `workspaceId`).
  ///
  /// `excludedSlot` identifies which anchor slot is about to be overwritten so that
  /// re-assigning the same channel ID to the same slot is treated as a legal no-op
  /// rather than a conflict.
  func checkChannelUniqueness(
    state : WorkspacesState,
    workspaceId : Nat,
    channelId : Text,
    excludedSlot : { #admin; #member },
  ) : Result.Result<(), Text> {
    for ((_, existing) in Map.entries(state.workspaces)) {
      let isSameWorkspace = Nat.equal(existing.id, workspaceId);
      // Admin anchor — skip only when this is the exact slot being replaced.
      if (not (isSameWorkspace and excludedSlot == #admin)) {
        switch (existing.adminChannelId) {
          case (?ch) {
            if (Text.equal(ch, channelId)) {
              return #err(
                if isSameWorkspace "Channel is already used as the admin anchor of this workspace." else "Channel is already used as an admin anchor in another workspace."
              );
            };
          };
          case (null) {};
        };
      };
      // Member anchor — skip only when this is the exact slot being replaced.
      if (not (isSameWorkspace and excludedSlot == #member)) {
        switch (existing.memberChannelId) {
          case (?ch) {
            if (Text.equal(ch, channelId)) {
              return #err(
                if isSameWorkspace "Channel is already used as the member anchor of this workspace." else "Channel is already used as a member anchor in another workspace."
              );
            };
          };
          case (null) {};
        };
      };
    };
    #ok(());
  };

  /// Look up a single workspace record by ID.
  /// Returns null if the workspace does not exist.
  public func getWorkspace(state : WorkspacesState, workspaceId : Nat) : ?WorkspaceRecord {
    Map.get(state.workspaces, Nat.compare, workspaceId);
  };

  /// Set the admin channel anchor for a workspace.
  /// The members of this Slack channel will be treated as workspace admins.
  /// Returns `#err` if the workspace does not exist or the channel ID is already
  /// used as any anchor (channel IDs must be globally unique across all anchors
  /// to keep channel→workspace resolution unambiguous).
  public func setAdminChannel(state : WorkspacesState, workspaceId : Nat, channelId : Text) : Result.Result<(), Text> {
    switch (Map.get(state.workspaces, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?record) {
        switch (checkChannelUniqueness(state, workspaceId, channelId, #admin)) {
          case (#err(msg)) { #err(msg) };
          case (#ok()) {
            let updated : WorkspaceRecord = {
              id = record.id;
              name = record.name;
              adminChannelId = ?channelId;
              memberChannelId = record.memberChannelId;
            };
            Map.add(state.workspaces, Nat.compare, workspaceId, updated);
            #ok(());
          };
        };
      };
    };
  };

  /// Set the member channel anchor for a workspace.
  /// The members of this Slack channel will be treated as workspace members.
  /// Returns `#err` if the workspace does not exist or the channel ID is already
  /// used as any anchor (channel IDs must be globally unique across all anchors
  /// to keep channel→workspace resolution unambiguous).
  public func setMemberChannel(state : WorkspacesState, workspaceId : Nat, channelId : Text) : Result.Result<(), Text> {
    switch (Map.get(state.workspaces, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?record) {
        switch (checkChannelUniqueness(state, workspaceId, channelId, #member)) {
          case (#err(msg)) { #err(msg) };
          case (#ok()) {
            let updated : WorkspaceRecord = {
              id = record.id;
              name = record.name;
              adminChannelId = record.adminChannelId;
              memberChannelId = ?channelId;
            };
            Map.add(state.workspaces, Nat.compare, workspaceId, updated);
            #ok(());
          };
        };
      };
    };
  };

  // ============================================
  // Channel Resolution
  // ============================================

  /// Resolve a Slack channel ID against all workspace channel anchors.
  ///
  /// Iterates all workspace records and returns:
  ///   `#adminChannel(workspaceId)` if the channel is the admin channel of that workspace
  ///   `#memberChannel(workspaceId)` if the channel is the member channel of that workspace
  ///   `#none` if the channel is not anchored to any workspace
  ///
  /// Admin channel is checked first; if a channel is somehow set as both (misconfiguration),
  /// `#adminChannel` takes precedence.
  public func resolveWorkspaceByChannel(state : WorkspacesState, channelId : Text) : ChannelResolution {
    for ((_, record) in Map.entries(state.workspaces)) {
      switch (record.adminChannelId) {
        case (?adminCh) {
          if (Text.equal(adminCh, channelId)) {
            return #adminChannel(record.id);
          };
        };
        case (null) {};
      };
      switch (record.memberChannelId) {
        case (?memberCh) {
          if (Text.equal(memberCh, channelId)) {
            return #memberChannel(record.id);
          };
        };
        case (null) {};
      };
    };
    #none;
  };
};
