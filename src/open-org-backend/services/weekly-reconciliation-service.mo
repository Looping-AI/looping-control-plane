/// Weekly Reconciliation Service
/// Runs on Sundays to sync the Slack user cache and verify all tracked channel anchors.
///
/// Full sweep (two parts):
///
/// 1. **User refresh** — calls `users.list` and upserts every org member into the
///    SlackUserCache, preserving existing `isOrgAdmin` and `workspaceMemberships`
///    flags while refreshing `displayName`, `isPrimaryOwner`, etc.
///
/// 2. **Channel sync** — for every tracked channel anchor (org admin, workspace admin,
///    workspace member), fetches the live member list from Slack and reconciles the
///    corresponding flags in the SlackUserCache:
///      - Users still in the channel keep (or gain) the flag.
///      - Users who have left the channel lose the flag (guard against missed events).
///
/// Channel verification (run alongside sync):
///   - **Org admin channel gone**: log + notify the Primary Owner via DM.
///       TODO: When the Task system is implemented (Phase 2+), replace the DM with a
///             Task of type #orgAdminChannelRecovery that guides the Primary Owner
///             through re-anchoring. The postMessage here is the interim workaround.
///   - **Workspace admin channel gone**: notify `#looping-ai-org-admins`.
///   - **Workspace member channel gone**: notify the workspace's admin channel
///     (or fall back to the org admin channel if no admin channel is configured).

import Text "mo:core/Text";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import SlackUserModel "../models/slack-user-model";
import WorkspaceModel "../models/workspace-model";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";

module {

  // ============================================
  // Types
  // ============================================

  /// Summary returned after a reconciliation run — useful for logging and tests.
  public type ReconciliationSummary = {
    usersRefreshed : Nat;
    orgAdminChannelOk : Bool;
    workspacesChecked : Nat;
    goneChannels : [Text]; // Channel IDs that could not be read from Slack
    errors : [Text]; // Non-fatal errors (e.g. failed DMs)
  };

  // ============================================
  // Private Helpers
  // ============================================

  /// Find the Primary Owner's Slack user ID from the cache.
  private func findPrimaryOwner(slackUsers : SlackUserModel.SlackUserCache) : ?Text {
    for (entry in Map.values(slackUsers)) {
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
  /// - Users in `freshMemberIds` → `isOrgAdmin = true`.
  /// - Cached users with `isOrgAdmin = true` that are NOT in `freshMemberIds` → cleared.
  private func syncOrgAdminMembership(
    slackUsers : SlackUserModel.SlackUserCache,
    freshMemberIds : [Text],
  ) {
    let freshSet = makeIdSet(freshMemberIds);

    // Clear isOrgAdmin for users no longer in the channel
    for (entry in Map.values(slackUsers)) {
      if (entry.isOrgAdmin) {
        if (Map.get(freshSet, Text.compare, entry.slackUserId) == null) {
          SlackUserModel.upsertUser(
            slackUsers,
            {
              slackUserId = entry.slackUserId;
              displayName = entry.displayName;
              isPrimaryOwner = entry.isPrimaryOwner;
              isOrgAdmin = false;
              workspaceMemberships = entry.workspaceMemberships;
            },
          );
        };
      };
    };

    // Grant isOrgAdmin for current channel members
    for (memberId in freshMemberIds.vals()) {
      switch (SlackUserModel.lookupUser(slackUsers, memberId)) {
        case (null) {
          // User not yet in cache — will be added by users.list sync or next team_join event.
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
                workspaceMemberships = entry.workspaceMemberships;
              },
            );
          };
        };
      };
    };
  };

  /// Reconcile the `inAdminChannel` or `inMemberChannel` flag for a specific workspace
  /// against a fresh member list obtained from Slack.
  ///
  /// - Cached users with the flag set but absent from `freshMemberIds` → flag cleared.
  /// - IDs in `freshMemberIds` that are in the cache → flag set.
  private func syncWorkspaceChannelMembership(
    slackUsers : SlackUserModel.SlackUserCache,
    workspaceId : Nat,
    freshMemberIds : [Text],
    slot : { #admin; #member },
  ) {
    let freshSet = makeIdSet(freshMemberIds);

    // Clear the flag for users no longer in this channel
    for (entry in Map.values(slackUsers)) {
      switch (Map.get(entry.workspaceMemberships, Nat.compare, workspaceId)) {
        case (null) {};
        case (?flags) {
          let hasFlag = switch (slot) {
            case (#admin) { flags.inAdminChannel };
            case (#member) { flags.inMemberChannel };
          };
          if (hasFlag and Map.get(freshSet, Text.compare, entry.slackUserId) == null) {
            switch (slot) {
              case (#admin) {
                ignore SlackUserModel.leaveAdminChannel(slackUsers, entry.slackUserId, workspaceId);
              };
              case (#member) {
                ignore SlackUserModel.leaveMemberChannel(slackUsers, entry.slackUserId, workspaceId);
              };
            };
          };
        };
      };
    };

    // Grant the flag for fresh members that are already in the cache
    for (memberId in freshMemberIds.vals()) {
      switch (SlackUserModel.lookupUser(slackUsers, memberId)) {
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
              ignore SlackUserModel.joinAdminChannel(slackUsers, memberId, workspaceId);
            };
            case (#member) {
              ignore SlackUserModel.joinMemberChannel(slackUsers, memberId, workspaceId);
            };
          };
        };
      };
    };
  };

  // ============================================
  // Public — Main Entry Point
  // ============================================

  /// Run the full weekly reconciliation.
  ///
  /// @param token          Decrypted Slack bot token (xoxb-...)
  /// @param slackUsers     Slack user cache (mutated in-place)
  /// @param workspaces     Workspace registry (read-only during reconciliation)
  /// @param orgAdminChannel  Org-admin channel anchor (may be null if not yet configured)
  /// @returns Summary of what was refreshed/synced and any errors encountered
  public func run(
    token : Text,
    slackUsers : SlackUserModel.SlackUserCache,
    workspaces : WorkspaceModel.WorkspacesState,
    orgAdminChannel : ?WorkspaceModel.OrgAdminChannelAnchor,
  ) : async ReconciliationSummary {
    var usersRefreshed : Nat = 0;
    var orgAdminChannelOk : Bool = true;
    var workspacesChecked : Nat = 0;
    var goneChannels : [Text] = [];
    var errors : [Text] = [];

    Logger.log(#info, ?"WeeklyReconciliation", "Starting weekly reconciliation...");

    // ---- Step 1: Refresh all org users from users.list ----
    switch (await SlackWrapper.getOrganizationMembers(token)) {
      case (#err(e)) {
        let msg = "Failed to fetch org users from Slack — aborting reconciliation: " # e;
        Logger.log(#error, ?"WeeklyReconciliation", msg);
        return {
          usersRefreshed = 0;
          orgAdminChannelOk = false;
          workspacesChecked = 0;
          goneChannels = [];
          errors = [msg];
        };
      };
      case (#ok(allUsers)) {
        for (user in allUsers.vals()) {
          // Preserve existing isOrgAdmin and workspaceMemberships — only refresh top-level fields.
          let (isOrgAdmin, workspaceMemberships) = switch (SlackUserModel.lookupUser(slackUsers, user.id)) {
            case (null) {
              (false, Map.empty<Nat, SlackUserModel.WorkspaceChannelFlags>());
            };
            case (?existing) {
              (existing.isOrgAdmin, existing.workspaceMemberships);
            };
          };
          SlackUserModel.upsertUser(
            slackUsers,
            {
              slackUserId = user.id;
              displayName = user.name;
              isPrimaryOwner = user.isPrimaryOwner;
              isOrgAdmin;
              workspaceMemberships;
            },
          );
          usersRefreshed += 1;
        };
        Logger.log(
          #info,
          ?"WeeklyReconciliation",
          "Refreshed " # Nat.toText(usersRefreshed) # " org users.",
        );
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
            goneChannels := Array.concat(goneChannels, [anchor.channelId]);
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
            switch (findPrimaryOwner(slackUsers)) {
              case (null) {
                let msg = "Org admin channel gone and Primary Owner not found in cache — cannot send recovery DM.";
                Logger.log(#warn, ?"WeeklyReconciliation", msg);
                errors := Array.concat(errors, [msg]);
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
                    errors := Array.concat(errors, [msg]);
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
            Logger.log(
              #info,
              ?"WeeklyReconciliation",
              "Synced org admin channel: " # Nat.toText(freshMembers.size()) # " members.",
            );
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
              goneChannels := Array.concat(goneChannels, [adminChanId]);
              Logger.log(
                #error,
                ?"WeeklyReconciliation",
                "Workspace " # Nat.toText(ws.id) # " (" # ws.name # ") admin channel gone " #
                "(channelId: " # adminChanId # "): " # e,
              );
              // Notify org admin channel
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
                      errors := Array.concat(errors, [msg]);
                    };
                    case (#ok(_)) {};
                  };
                };
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
              goneChannels := Array.concat(goneChannels, [memberChanId]);
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
                      errors := Array.concat(errors, [msg]);
                    };
                    case (#ok(_)) {};
                  };
                };
                case (null) {
                  // No workspace admin channel — fall back to org admin channel
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
                          errors := Array.concat(errors, [msg]);
                        };
                        case (#ok(_)) {};
                      };
                    };
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

    Logger.log(
      #info,
      ?"WeeklyReconciliation",
      "Weekly reconciliation complete: " #
      Nat.toText(usersRefreshed) # " users refreshed, " #
      Nat.toText(workspacesChecked) # " workspaces checked, " #
      Nat.toText(goneChannels.size()) # " gone channel(s).",
    );

    {
      usersRefreshed;
      orgAdminChannelOk;
      workspacesChecked;
      goneChannels;
      errors;
    };
  };
};
