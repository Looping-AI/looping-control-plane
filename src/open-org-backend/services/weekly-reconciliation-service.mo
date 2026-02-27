/// Weekly Reconciliation Service
/// Runs on Sundays to sync the Slack user cache and verify all tracked channel anchors.
///
/// Full sweep (three parts):
///
/// 1. **User refresh** — calls `users.list` and compares each org member against the
///    cache. Only new users or users with profile changes (displayName, isPrimaryOwner,
///    isBot) are upserted. Existing `isOrgAdmin` and `workspaceMemberships` flags are
///    preserved and not touched here (those are reconciled by the channel sync steps).
///    After the comparison loop, any users still in the cache but **absent** from the
///    fresh `users.list` are removed as stale (deleted/deactivated in Slack).
///
/// 2. **Org admin channel sync** — fetches the live member list of the org admin
///    channel and reconciles the `isOrgAdmin` flag.
///
/// 3. **Workspace channel sync** — for every tracked channel anchor (workspace admin,
///    workspace member), fetches the live member list from Slack and reconciles the
///    corresponding flags in the SlackUserState:
///      - Users still in the channel keep (or gain) the flag.
///      - Users who have left the channel lose the flag (guard against missed events).
///
/// Channel verification (run alongside sync):
///   - **Org admin channel gone**: log + notify the Primary Owner via DM.
///       TODO: When the Task system is implemented (Phase 2+), replace the DM with a
///             Task of type #orgAdminChannelRecovery that guides the Primary Owner
///             through re-anchoring. The postMessage here is the interim workaround.
///   - **Workspace admin channel gone**: notify `#looping-ai-org-admins` (only if
///       the org admin channel is still accessible).
///   - **Workspace member channel gone**: notify the workspace's admin channel
///     (or fall back to the org admin channel if no admin channel is configured,
///      and only if the target channel is still accessible).
///
/// At the end, access change log entries older than the retention period are purged.
/// The reconciliation summary includes audit-oriented fields derived from the change
/// log entries produced during this run (source == #reconciliation).

import Text "mo:core/Text";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Constants "../constants";
import SlackUserModel "../models/slack-user-model";
import WorkspaceModel "../models/workspace-model";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";

module {

  // ============================================
  // Types
  // ============================================

  /// A workspace-scoped access change entry for the reconciliation summary.
  public type WorkspaceScopeChange = {
    slackUserId : Text;
    workspaceId : Nat;
    changeType : {
      #adminGranted;
      #adminRevoked;
      #memberGranted;
      #memberRevoked;
    };
  };

  /// Summary returned after a reconciliation run — useful for logging, tests, and auditing.
  public type ReconciliationSummary = {
    usersUpdated : Nat; // Users that were newly added or had profile changes (displayName / isPrimaryOwner / isBot)
    orgAdminChannelOk : Bool;
    workspacesChecked : Nat;
    goneChannels : [Text];
    errors : [Text];
    // Audit fields — derived from access change log entries produced during this run
    orgAdminsGranted : [Text];
    orgAdminsRevoked : [Text];
    workspaceScopeChanges : [WorkspaceScopeChange];
    staleUsersRemoved : [Text];
    logsPurged : Nat;
  };

  // ============================================
  // Private Helpers
  // ============================================

  /// Find the Primary Owner's Slack user ID from the cache.
  private func findPrimaryOwner(cache : SlackUserModel.SlackUserCache) : ?Text {
    for (entry in Map.values(cache)) {
      if (entry.isPrimaryOwner) { return ?entry.slackUserId };
    };
    null;
  };

  /// Build a lookup-friendly set from an array of IDs (Map<Text, ()> for O(log n) membership tests).
  private func makeIdSet(ids : [Text]) : Map.Map<Text, ()> {
    let set = Map.empty<Text, ()>();
    for (id in ids.vals()) {
      Map.add(set, Text.compare, id, ());
    };
    set;
  };

  /// Reconcile the `isOrgAdmin` flag for all cached users against a fresh member list.
  ///
  /// Uses collect-then-apply to avoid mutating the cache during iteration.
  /// - Cached users with `isOrgAdmin = true` that are NOT in `freshMemberIds` → cleared.
  /// - Users in `freshMemberIds` → `isOrgAdmin = true`.
  private func syncOrgAdminMembership(
    slackUsers : SlackUserModel.SlackUserState,
    freshMemberIds : [Text],
  ) {
    let freshSet = makeIdSet(freshMemberIds);

    // Phase 1: Collect IDs whose isOrgAdmin must be cleared
    let toRevoke = List.empty<Text>();
    for (entry in Map.values(slackUsers.cache)) {
      if (entry.isOrgAdmin) {
        if (Map.get(freshSet, Text.compare, entry.slackUserId) == null) {
          List.add(toRevoke, entry.slackUserId);
        };
      };
    };

    // Phase 2: Apply revocations
    for (userId in List.values(toRevoke)) {
      switch (SlackUserModel.lookupUser(slackUsers.cache, userId)) {
        case (null) {};
        case (?entry) {
          SlackUserModel.upsertUser(
            slackUsers,
            {
              slackUserId = entry.slackUserId;
              displayName = entry.displayName;
              isPrimaryOwner = entry.isPrimaryOwner;
              isOrgAdmin = false;
              isBot = entry.isBot;
              workspaceMemberships = entry.workspaceMemberships;
            },
            #reconciliation,
          );
        };
      };
    };

    // Phase 3: Grant isOrgAdmin for current channel members
    for (memberId in freshMemberIds.vals()) {
      switch (SlackUserModel.lookupUser(slackUsers.cache, memberId)) {
        case (null) {
          Logger.log(
            #warn,
            ?"WeeklyReconciliation",
            "Org admin channel member not found in user cache (sync lag?): " # memberId,
          );
        };
        case (?entry) {
          if (not entry.isOrgAdmin) {
            SlackUserModel.upsertUser(
              slackUsers,
              {
                slackUserId = entry.slackUserId;
                displayName = entry.displayName;
                isPrimaryOwner = entry.isPrimaryOwner;
                isOrgAdmin = true;
                isBot = entry.isBot;
                workspaceMemberships = entry.workspaceMemberships;
              },
              #reconciliation,
            );
          };
        };
      };
    };
  };

  /// Reconcile the `inAdminChannel` or `inMemberChannel` flag for a specific workspace
  /// against a fresh member list obtained from Slack.
  ///
  /// Uses collect-then-apply to avoid mutating the cache during iteration.
  /// - Cached users with the flag set but absent from `freshMemberIds` → flag cleared.
  /// - IDs in `freshMemberIds` that are in the cache → flag set.
  private func syncWorkspaceChannelMembership(
    slackUsers : SlackUserModel.SlackUserState,
    workspaceId : Nat,
    freshMemberIds : [Text],
    slot : { #admin; #member },
  ) {
    let freshSet = makeIdSet(freshMemberIds);

    // Phase 1: Collect IDs whose channel flag must be cleared
    let toRevoke = List.empty<Text>();
    for (entry in Map.values(slackUsers.cache)) {
      switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
        case (null) {};
        case (?flags) {
          let hasFlag = switch (slot) {
            case (#admin) { flags.inAdminChannel };
            case (#member) { flags.inMemberChannel };
          };
          if (hasFlag and Map.get(freshSet, Text.compare, entry.slackUserId) == null) {
            List.add(toRevoke, entry.slackUserId);
          };
        };
      };
    };

    // Phase 2: Apply revocations
    for (userId in List.values(toRevoke)) {
      switch (slot) {
        case (#admin) {
          ignore SlackUserModel.leaveAdminChannel(slackUsers, userId, workspaceId, #reconciliation);
        };
        case (#member) {
          ignore SlackUserModel.leaveMemberChannel(slackUsers, userId, workspaceId, #reconciliation);
        };
      };
    };

    // Phase 3: Grant the flag for fresh members that are already in the cache
    for (memberId in freshMemberIds.vals()) {
      switch (SlackUserModel.lookupUser(slackUsers.cache, memberId)) {
        case (null) {
          Logger.log(
            #warn,
            ?"WeeklyReconciliation",
            "Workspace " # Nat.toText(workspaceId) # " channel member not found in user cache: " # memberId,
          );
        };
        case (?_) {
          switch (slot) {
            case (#admin) {
              ignore SlackUserModel.joinAdminChannel(slackUsers, memberId, workspaceId, #reconciliation);
            };
            case (#member) {
              ignore SlackUserModel.joinMemberChannel(slackUsers, memberId, workspaceId, #reconciliation);
            };
          };
        };
      };
    };
  };

  /// Build audit-oriented summary fields from access change log entries produced
  /// during this run (source == #reconciliation, timestamp >= runStartTime).
  private func buildAuditSummary(
    slackUsers : SlackUserModel.SlackUserState,
    runStartTime : Int,
  ) : {
    orgAdminsGranted : [Text];
    orgAdminsRevoked : [Text];
    workspaceScopeChanges : [WorkspaceScopeChange];
    staleUsersRemoved : [Text];
  } {
    let orgGranted = List.empty<Text>();
    let orgRevoked = List.empty<Text>();
    let scopeChanges = List.empty<WorkspaceScopeChange>();
    let staleRemoved = List.empty<Text>();

    let entries = SlackUserModel.getLogsSince(slackUsers, runStartTime);
    for (entry in entries.vals()) {
      // Only include entries from this reconciliation run
      switch (entry.source) {
        case (#reconciliation) {
          switch (entry.changeType) {
            case (#orgAdminGranted) { List.add(orgGranted, entry.slackUserId) };
            case (#orgAdminRevoked) { List.add(orgRevoked, entry.slackUserId) };
            case (#userRemoved) { List.add(staleRemoved, entry.slackUserId) };
            case (#workspaceAdminGranted(wsId)) {
              List.add(scopeChanges, { slackUserId = entry.slackUserId; workspaceId = wsId; changeType = #adminGranted });
            };
            case (#workspaceAdminRevoked(wsId)) {
              List.add(scopeChanges, { slackUserId = entry.slackUserId; workspaceId = wsId; changeType = #adminRevoked });
            };
            case (#workspaceMemberGranted(wsId)) {
              List.add(scopeChanges, { slackUserId = entry.slackUserId; workspaceId = wsId; changeType = #memberGranted });
            };
            case (#workspaceMemberRevoked(wsId)) {
              List.add(scopeChanges, { slackUserId = entry.slackUserId; workspaceId = wsId; changeType = #memberRevoked });
            };
            case (_) {}; // #userAdded, #primaryOwnerGranted/Revoked — not included in these summary fields
          };
        };
        case (_) {}; // ignore non-reconciliation entries
      };
    };

    {
      orgAdminsGranted = List.toArray(orgGranted);
      orgAdminsRevoked = List.toArray(orgRevoked);
      workspaceScopeChanges = List.toArray(scopeChanges);
      staleUsersRemoved = List.toArray(staleRemoved);
    };
  };

  // ============================================
  // Public — Main Entry Point
  // ============================================

  /// Run the full weekly reconciliation.
  ///
  /// @param token          Decrypted Slack bot token (xoxb-...)
  /// @param slackUsers     Slack user state (mutated in-place; changes are auto-logged)
  /// @param workspaces     Workspace registry (read-only during reconciliation)
  /// @param orgAdminChannel  Org-admin channel anchor (may be null if not yet configured)
  /// @returns Summary of user updates, channel syncs, and any errors encountered
  public func run(
    token : Text,
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
    orgAdminChannel : ?WorkspaceModel.OrgAdminChannelAnchor,
  ) : async ReconciliationSummary {
    let runStartTime = Time.now();
    var usersUpdated : Nat = 0;
    var orgAdminChannelOk : Bool = true;
    var workspacesChecked : Nat = 0;
    let goneChannels = List.empty<Text>();
    let errors = List.empty<Text>();

    // ---- Step 1: Refresh all org users from users.list ----
    switch (await SlackWrapper.getOrganizationMembers(token)) {
      case (#err(e)) {
        let msg = "Failed to fetch org users from Slack — aborting reconciliation: " # e;
        Logger.log(#error, ?"WeeklyReconciliation", msg);
        return {
          usersUpdated = 0;
          orgAdminChannelOk = false;
          workspacesChecked = 0;
          goneChannels = [];
          errors = [msg];
          orgAdminsGranted = [];
          orgAdminsRevoked = [];
          workspaceScopeChanges = [];
          staleUsersRemoved = [];
          logsPurged = 0;
        };
      };
      case (#ok(allUsers)) {
        // Build a set of all IDs from users.list for stale user pruning later
        let freshUserIds = makeIdSet(
          Iter.toArray(
            Iter.map<SlackWrapper.SlackUser, Text>(
              allUsers.vals(),
              func(u) { u.id },
            )
          )
        );

        for (user in allUsers.vals()) {
          // Preserve existing isOrgAdmin and workspaceMemberships — only refresh top-level fields.
          // Skip the upsert entirely when nothing has changed to avoid unnecessary log entries.
          let (isOrgAdmin, workspaceMemberships, needsUpdate) = switch (SlackUserModel.lookupUser(slackUsers.cache, user.id)) {
            case (null) {
              // New user — always write
              (false, Map.empty<Nat, SlackUserModel.WorkspaceChannelFlags>(), true);
            };
            case (?existing) {
              let changed = existing.displayName != user.name or existing.isPrimaryOwner != user.isPrimaryOwner or existing.isBot != user.isBot;
              (existing.isOrgAdmin, existing.workspaceMemberships, changed);
            };
          };
          if (needsUpdate) {
            SlackUserModel.upsertUser(
              slackUsers,
              {
                slackUserId = user.id;
                displayName = user.name;
                isPrimaryOwner = user.isPrimaryOwner;
                isOrgAdmin;
                isBot = user.isBot;
                workspaceMemberships;
              },
              #reconciliation,
            );
            usersUpdated += 1;
          };
        };

        // Prune stale users: anyone in cache but absent from users.list
        // Collect first to avoid mutation-during-iteration.
        let staleIds = List.empty<Text>();
        for (entry in Map.values(slackUsers.cache)) {
          if (Map.get(freshUserIds, Text.compare, entry.slackUserId) == null) {
            List.add(staleIds, entry.slackUserId);
          };
        };
        for (id in List.values(staleIds)) {
          ignore SlackUserModel.removeUser(slackUsers, id, #reconciliation);
        };
      };
    };

    // ---- Step 2: Sync org admin channel ----
    switch (orgAdminChannel) {
      case (null) {
        Logger.log(
          #info,
          ?"WeeklyReconciliation",
          "No org admin channel anchor configured; skipping org admin sync.",
        );
      };
      case (?anchor) {
        switch (await SlackWrapper.getChannelMembers(token, anchor.channelId)) {
          case (#err(e)) {
            orgAdminChannelOk := false;
            List.add(goneChannels, anchor.channelId);
            Logger.log(
              #error,
              ?"WeeklyReconciliation",
              "Org admin channel is gone or inaccessible (channelId: " # anchor.channelId # "): " # e,
            );

            // TODO: Once the Task system is implemented (Phase 2+), replace this
            //       postMessage with a Task of type #orgAdminChannelRecovery.
            //       The Task should carry the missing channel's ID and guide the
            //       Primary Owner through re-anchoring the org admin channel via
            //       an interactive Slack flow (Phase 6). The DM below is the
            //       interim notification until that infrastructure exists.
            switch (findPrimaryOwner(slackUsers.cache)) {
              case (null) {
                let msg = "Org admin channel gone and Primary Owner not found in cache — cannot send recovery DM.";
                Logger.log(#warn, ?"WeeklyReconciliation", msg);
                List.add(errors, msg);
              };
              case (?ownerId) {
                let dmText = ":warning: *Looping AI — Org Admin Channel Issue*\n\n" #
                "The org admin channel `#" # anchor.channelName # "` " #
                "(ID: `" # anchor.channelId # "`) is no longer accessible.\n\n" #
                "Please re-create or re-anchor it so org-level access continues to work. " #
                "Once done, update the channel anchor via the Looping AI configuration.";
                switch (await SlackWrapper.postMessage(token, ownerId, dmText, null)) {
                  case (#err(e2)) {
                    let msg = "Failed to DM Primary Owner about org admin channel issue: " # e2;
                    Logger.log(#error, ?"WeeklyReconciliation", msg);
                    List.add(errors, msg);
                  };
                  case (#ok(_)) {
                    Logger.log(
                      #info,
                      ?"WeeklyReconciliation",
                      "Sent recovery DM to Primary Owner (" # ownerId # ").",
                    );
                  };
                };
              };
            };
          };
          case (#ok(freshMembers)) {
            syncOrgAdminMembership(slackUsers, freshMembers);
          };
        };
      };
    };

    // ---- Step 3: Sync workspace channel anchors ----
    let allWorkspaces = WorkspaceModel.listWorkspaces(workspaces);
    for (ws in allWorkspaces.vals()) {
      workspacesChecked += 1;

      // -- Admin channel for this workspace --
      switch (ws.adminChannelId) {
        case (null) {};
        case (?adminChanId) {
          switch (await SlackWrapper.getChannelMembers(token, adminChanId)) {
            case (#err(e)) {
              List.add(goneChannels, adminChanId);
              Logger.log(
                #error,
                ?"WeeklyReconciliation",
                "Workspace " # Nat.toText(ws.id) # " (" # ws.name # ") admin channel gone " #
                "(channelId: " # adminChanId # "): " # e,
              );
              // Notify org admin channel only if it's still accessible
              if (orgAdminChannelOk) {
                switch (orgAdminChannel) {
                  case (null) {
                    Logger.log(
                      #warn,
                      ?"WeeklyReconciliation",
                      "No org admin channel configured to notify about gone admin channel " #
                      "for workspace " # Nat.toText(ws.id) # " (" # ws.name # ").",
                    );
                  };
                  case (?anchor) {
                    let notifyText = ":warning: *Looping AI — Workspace Admin Channel Issue*\n\n" #
                    "The admin channel for workspace *" # ws.name # "* " #
                    "(ID: `" # adminChanId # "`) is no longer accessible.\n\n" #
                    "Please assign a new admin channel for this workspace, or request workspace deletion.";
                    switch (await SlackWrapper.postMessage(token, anchor.channelId, notifyText, null)) {
                      case (#err(e2)) {
                        let msg = "Failed to notify org admin channel about gone workspace admin channel: " # e2;
                        Logger.log(#error, ?"WeeklyReconciliation", msg);
                        List.add(errors, msg);
                      };
                      case (#ok(_)) {};
                    };
                  };
                };
              } else {
                Logger.log(
                  #warn,
                  ?"WeeklyReconciliation",
                  "Skipping notification for gone admin channel (workspace " # Nat.toText(ws.id) #
                  ") — org admin channel is also inaccessible.",
                );
              };
            };
            case (#ok(freshMembers)) {
              syncWorkspaceChannelMembership(slackUsers, ws.id, freshMembers, #admin);
            };
          };
        };
      };

      // -- Member channel for this workspace --
      switch (ws.memberChannelId) {
        case (null) {};
        case (?memberChanId) {
          switch (await SlackWrapper.getChannelMembers(token, memberChanId)) {
            case (#err(e)) {
              List.add(goneChannels, memberChanId);
              Logger.log(
                #error,
                ?"WeeklyReconciliation",
                "Workspace " # Nat.toText(ws.id) # " (" # ws.name # ") member channel gone " #
                "(channelId: " # memberChanId # "): " # e,
              );
              // Notify workspace admin channel (fall back to org admin channel)
              switch (ws.adminChannelId) {
                case (?adminChanId) {
                  let notifyText = ":warning: *Looping AI — Workspace Member Channel Issue*\n\n" #
                  "The member channel for workspace *" # ws.name # "* " #
                  "(ID: `" # memberChanId # "`) is no longer accessible.\n\n" #
                  "Please assign a new member channel for this workspace.";
                  switch (await SlackWrapper.postMessage(token, adminChanId, notifyText, null)) {
                    case (#err(e2)) {
                      let msg = "Failed to notify workspace admin channel about gone member channel: " # e2;
                      Logger.log(#error, ?"WeeklyReconciliation", msg);
                      List.add(errors, msg);
                    };
                    case (#ok(_)) {};
                  };
                };
                case (null) {
                  // No workspace admin channel — fall back to org admin channel (only if accessible)
                  if (orgAdminChannelOk) {
                    switch (orgAdminChannel) {
                      case (null) {
                        Logger.log(
                          #warn,
                          ?"WeeklyReconciliation",
                          "Neither workspace admin channel nor org admin channel available to notify " #
                          "about gone member channel for workspace " # Nat.toText(ws.id) # " (" # ws.name # ").",
                        );
                      };
                      case (?anchor) {
                        let notifyText = ":warning: *Looping AI — Workspace Member Channel Issue*\n\n" #
                        "The member channel for workspace *" # ws.name # "* " #
                        "(ID: `" # memberChanId # "`) is no longer accessible, " #
                        "and no admin channel is configured for this workspace.\n\n" #
                        "Please assign a new member channel or admin channel for workspace *" # ws.name # "*.";
                        switch (await SlackWrapper.postMessage(token, anchor.channelId, notifyText, null)) {
                          case (#err(e2)) {
                            let msg = "Failed to notify org admin channel about gone member channel: " # e2;
                            Logger.log(#error, ?"WeeklyReconciliation", msg);
                            List.add(errors, msg);
                          };
                          case (#ok(_)) {};
                        };
                      };
                    };
                  } else {
                    Logger.log(
                      #warn,
                      ?"WeeklyReconciliation",
                      "Skipping notification for gone member channel (workspace " # Nat.toText(ws.id) #
                      ") — org admin channel is also inaccessible.",
                    );
                  };
                };
              };
            };
            case (#ok(freshMembers)) {
              syncWorkspaceChannelMembership(slackUsers, ws.id, freshMembers, #member);
            };
          };
        };
      };
    };

    // ---- Step 4: Purge old access change log entries ----
    let logsPurged = SlackUserModel.purgeOldLogs(slackUsers, Constants.ACCESS_LOG_RETENTION_NS);
    if (logsPurged > 0) {
      Logger.log(
        #info,
        ?"WeeklyReconciliation",
        "Purged " # Nat.toText(logsPurged) # " old access change log entries.",
      );
    };

    // ---- Build audit summary from log entries produced during this run ----
    let audit = buildAuditSummary(slackUsers, runStartTime);

    Logger.log(
      #info,
      ?"WeeklyReconciliation",
      "Weekly reconciliation complete: " #
      Nat.toText(usersUpdated) # " user(s) updated, " #
      Nat.toText(workspacesChecked) # " workspaces checked, " #
      Nat.toText(List.size(goneChannels)) # " gone channel(s), " #
      Nat.toText(audit.staleUsersRemoved.size()) # " stale user(s) removed.",
    );

    {
      usersUpdated;
      orgAdminChannelOk;
      workspacesChecked;
      goneChannels = List.toArray(goneChannels);
      errors = List.toArray(errors);
      orgAdminsGranted = audit.orgAdminsGranted;
      orgAdminsRevoked = audit.orgAdminsRevoked;
      workspaceScopeChanges = audit.workspaceScopeChanges;
      staleUsersRemoved = audit.staleUsersRemoved;
      logsPurged;
    };
  };
};
