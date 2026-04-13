/// Weekly Reconciliation Runner
/// Runs every 7 days to sync the Slack user cache and verify all tracked channel anchors.
///
/// Full sweep (three parts):
///
/// 1. **User refresh** — calls `users.list` and compares each org member against the
///    cache. Only new users or users with profile changes (displayName, isPrimaryOwner,
///    isBot) are upserted. Existing `isOrgAdmin` and `adminWorkspaces` flags are
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
import Set "mo:core/Set";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Constants "../constants";
import SlackUserModel "../models/slack-user-model";
import WorkspaceModel "../models/workspace-model";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";
import KeyDerivationService "../services/key-derivation-service";
import SecretModel "../models/secret-model";

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
    secretLogsPurged : Nat;
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
              adminWorkspaces = entry.adminWorkspaces;
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
                adminWorkspaces = entry.adminWorkspaces;
              },
              #reconciliation,
            );
          };
        };
      };
    };
  };

  /// Reconcile the admin workspace membership for a specific workspace
  /// against a fresh member list obtained from Slack.
  ///
  /// Uses collect-then-apply to avoid mutating the cache during iteration.
  /// - Cached users with admin membership but absent from `freshMemberIds` → membership removed.
  /// - IDs in `freshMemberIds` that are in the cache → membership granted.
  private func syncWorkspaceChannelMembership(
    slackUsers : SlackUserModel.SlackUserState,
    workspaceId : Nat,
    freshMemberIds : [Text],
  ) {
    let freshSet = makeIdSet(freshMemberIds);

    // Phase 1: Collect IDs whose admin flag must be cleared
    let toRevoke = List.empty<Text>();
    for (entry in Map.values(slackUsers.cache)) {
      if (Set.contains(entry.adminWorkspaces, Nat.compare, workspaceId) and Map.get(freshSet, Text.compare, entry.slackUserId) == null) {
        List.add(toRevoke, entry.slackUserId);
      };
    };

    // Phase 2: Apply revocations
    for (userId in List.values(toRevoke)) {
      ignore SlackUserModel.leaveAdminChannel(slackUsers, userId, workspaceId, #reconciliation);
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
          ignore SlackUserModel.joinAdminChannel(slackUsers, memberId, workspaceId, #reconciliation);
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

  /// Search all private channels for one named exactly `Constants.ORG_ADMIN_CHANNEL_NAME`.
  /// Returns the channel ID if found, or `null` on API error or if no match exists.
  /// NOTE: Only private channels are valid anchors — see `warnIfPublicOrgAdminChannelExists`
  ///       for the fallback that covers the case where one was accidentally created as public.
  private func findOrgAdminChannelByName(token : Text) : async ?Text {
    switch (await SlackWrapper.listChannels(token, ?"private_channel")) {
      case (#err(e)) {
        Logger.log(
          #warn,
          ?"WeeklyReconciliation",
          "Auto-discovery of org admin channel failed (listChannels error): " # e,
        );
        null;
      };
      case (#ok(channels)) {
        for (ch in channels.vals()) {
          if (ch.name == Constants.ORG_ADMIN_CHANNEL_NAME) {
            return ?ch.id;
          };
        };
        null;
      };
    };
  };

  /// After failing to find a *private* org-admin channel, check whether a *public* channel
  /// with the same name exists. If found, DM the Primary Owner to convert or recreate it
  /// as private — the channel is not anchored. Best-effort: silently skips on API errors.
  private func warnIfPublicOrgAdminChannelExists(
    token : Text,
    ownerCache : SlackUserModel.SlackUserCache,
  ) : async () {
    switch (await SlackWrapper.listChannels(token, ?"public_channel")) {
      case (#err(_)) {};
      case (#ok(channels)) {
        for (ch in channels.vals()) {
          if (ch.name == Constants.ORG_ADMIN_CHANNEL_NAME) {
            Logger.log(
              #warn,
              ?"WeeklyReconciliation",
              "Found public org admin channel (ID: " # ch.id # ") — org admin channels must be private.",
            );
            switch (findPrimaryOwner(ownerCache)) {
              case (null) {
                Logger.log(
                  #warn,
                  ?"WeeklyReconciliation",
                  "Cannot send public-channel warning DM — Primary Owner not found in cache.",
                );
              };
              case (?ownerId) {
                let warnText = ":warning: *Looping AI — Org Admin Channel Must Be Private*\n\n" #
                "A channel named `#" # Constants.ORG_ADMIN_CHANNEL_NAME # "` (ID: `" # ch.id # "`) was found, " #
                "but it is *public*. For security, the org-admin channel must be *private*.\n\n" #
                "Please convert the channel to private, or delete it and create a new private " #
                "channel named `#" # Constants.ORG_ADMIN_CHANNEL_NAME # "`.";
                switch (await SlackWrapper.postMessage(token, ownerId, warnText, null, null)) {
                  case (#err(e)) {
                    Logger.log(
                      #error,
                      ?"WeeklyReconciliation",
                      "Failed to DM Primary Owner about public org admin channel: " # e,
                    );
                  };
                  case (#ok(_)) {
                    Logger.log(
                      #info,
                      ?"WeeklyReconciliation",
                      "Sent public-channel warning DM to Primary Owner (" # ownerId # ").",
                    );
                  };
                };
              };
            };
            return;
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
  /// Resolves the Slack bot token from workspace 0 secrets, then performs
  /// a full users.list + conversations.members sweep and verifies all tracked
  /// channel anchors.
  ///
  /// @param keyCache       Encryption key cache (for decrypting the bot token)
  /// @param secrets        Encrypted secrets store (workspace ID → secrets map)
  /// @param slackUsers     Slack user state (mutated in-place; changes are auto-logged)
  /// @param workspaces     Workspace registry (read-only during reconciliation)
  /// @returns #ok with reconciliation summary, or #err if token is missing
  public func run(
    keyCache : KeyDerivationService.KeyCache,
    secrets : SecretModel.SecretsState,
    slackUsers : SlackUserModel.SlackUserState,
    workspaces : WorkspaceModel.WorkspacesState,
  ) : async { #ok : ReconciliationSummary; #err : Text } {
    // Resolve the bot token from workspace 0 secrets (global Slack integration secret).
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let token = switch (SecretModel.resolvePlatformSecret(secrets, encryptionKey, null, #slackBotToken, { slackUserId = null; agentId = null; operation = "weekly-reconciliation" })) {
      case (null) {
        return #err("No Slack bot token found for workspace 0");
      };
      case (?t) { t };
    };
    // Workspace 0 is the org workspace. Its adminChannelId IS the org-admin channel anchor.
    var orgAdminChannelId : ?Text = switch (Map.get(workspaces.workspaces, Nat.compare, 0)) {
      case (null) { Runtime.unreachable() };
      case (?ws0) { ws0.adminChannelId };
    };
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
        return #ok({
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
          secretLogsPurged = 0;
        });
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
          // Preserve existing isOrgAdmin and adminWorkspaces — only refresh top-level fields.
          // Skip the upsert entirely when nothing has changed to avoid unnecessary log entries.
          let (isOrgAdmin, adminWorkspaces, needsUpdate) = switch (SlackUserModel.lookupUser(slackUsers.cache, user.id)) {
            case (null) {
              // New user — always write
              (false, Set.empty<Nat>(), true);
            };
            case (?existing) {
              let changed = existing.displayName != user.name or existing.isPrimaryOwner != user.isPrimaryOwner or existing.isBot != user.isBot;
              (existing.isOrgAdmin, existing.adminWorkspaces, changed);
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
                adminWorkspaces;
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

    // ---- Step 2: Sync org admin channel (workspace 0's adminChannelId) ----
    // First verify the channel is accessible (via conversations.info) and that its
    // name is exactly '#looping-ai-org-admins', then sync member flags.
    switch (orgAdminChannelId) {
      case (null) {
        Logger.log(
          #info,
          ?"WeeklyReconciliation",
          "No org admin channel anchor configured — attempting auto-discovery by name.",
        );
        switch (await findOrgAdminChannelByName(token)) {
          case (null) {
            Logger.log(
              #warn,
              ?"WeeklyReconciliation",
              "Auto-discovery found no private channel named '#" # Constants.ORG_ADMIN_CHANNEL_NAME # "' — skipping org admin sync.",
            );
            await warnIfPublicOrgAdminChannelExists(token, slackUsers.cache);
          };
          case (?foundId) {
            switch (WorkspaceModel.setAdminChannel(workspaces, 0, foundId)) {
              case (#err(setErr)) {
                let msg = "Auto-discovery found org admin channel (ID: " # foundId # ") but failed to set anchor: " # setErr;
                Logger.log(#warn, ?"WeeklyReconciliation", msg);
                List.add(errors, msg);
              };
              case (#ok()) {
                orgAdminChannelId := ?foundId;
                Logger.log(
                  #info,
                  ?"WeeklyReconciliation",
                  "Auto-anchored org admin channel (ID: " # foundId # "); proceeding with member sync.",
                );
                switch (await SlackWrapper.getChannelMembers(token, foundId)) {
                  case (#err(e)) {
                    orgAdminChannelOk := false;
                    List.add(goneChannels, foundId);
                    let msg = "Org admin channel members fetch failed after auto-anchor (channelId: " # foundId # "): " # e;
                    Logger.log(#error, ?"WeeklyReconciliation", msg);
                    List.add(errors, msg);
                  };
                  case (#ok(freshMembers)) {
                    syncOrgAdminMembership(slackUsers, freshMembers);
                  };
                };
              };
            };
          };
        };
      };
      case (?channelId) {
        switch (await SlackWrapper.getChannelInfo(token, channelId)) {
          case (#err(e)) {
            // Channel is gone or inaccessible. Attempt auto-discovery before escalating.
            Logger.log(
              #error,
              ?"WeeklyReconciliation",
              "Org admin channel is gone or inaccessible (channelId: " # channelId # "): " # e,
            );
            switch (await findOrgAdminChannelByName(token)) {
              case (?foundId) {
                switch (WorkspaceModel.setAdminChannel(workspaces, 0, foundId)) {
                  case (#err(setErr)) {
                    orgAdminChannelOk := false;
                    List.add(goneChannels, channelId);
                    let msg = "Auto-discovery found org admin channel (ID: " # foundId # ") but failed to update anchor: " # setErr;
                    Logger.log(#warn, ?"WeeklyReconciliation", msg);
                    List.add(errors, msg);
                  };
                  case (#ok()) {
                    orgAdminChannelId := ?foundId;
                    Logger.log(
                      #info,
                      ?"WeeklyReconciliation",
                      "Auto-anchored org admin channel (ID: " # foundId # ") after old anchor (ID: " # channelId # ") became inaccessible.",
                    );
                    switch (await SlackWrapper.getChannelMembers(token, foundId)) {
                      case (#err(e2)) {
                        orgAdminChannelOk := false;
                        List.add(goneChannels, foundId);
                        let msg = "Org admin channel members fetch failed after auto-recovery (channelId: " # foundId # "): " # e2;
                        Logger.log(#error, ?"WeeklyReconciliation", msg);
                        List.add(errors, msg);
                      };
                      case (#ok(freshMembers)) {
                        syncOrgAdminMembership(slackUsers, freshMembers);
                      };
                    };
                  };
                };
              };
              case (null) {
                // No replacement found; mark as gone and notify Primary Owner.
                orgAdminChannelOk := false;
                List.add(goneChannels, channelId);
                switch (findPrimaryOwner(slackUsers.cache)) {
                  case (null) {
                    let msg = "Org admin channel gone and Primary Owner not found in cache — cannot send recovery DM.";
                    Logger.log(#warn, ?"WeeklyReconciliation", msg);
                    List.add(errors, msg);
                  };
                  case (?ownerId) {
                    let dmText = ":warning: *Looping AI — Org Admin Channel Issue*\n\n" #
                    "The org-admin channel (ID: `" # channelId # "`) is no longer accessible " #
                    "and no channel named `#" # Constants.ORG_ADMIN_CHANNEL_NAME # "` was found.\n\n" #
                    "Please re-create the channel with the correct name or re-anchor it so org-level access continues to work.";
                    switch (await SlackWrapper.postMessage(token, ownerId, dmText, null, null)) {
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
                await warnIfPublicOrgAdminChannelExists(token, slackUsers.cache);
              };
            };
          };
          case (#ok(channelInfo)) {
            // Channel is accessible. Determine the effective channel to sync from.
            // If the name is wrong, attempt auto-discovery to find (or re-anchor) the
            // correctly-named channel before falling back to a DM warning.
            var effectiveChannelId = channelId;
            if (channelInfo.name != Constants.ORG_ADMIN_CHANNEL_NAME) {
              Logger.log(
                #warn,
                ?"WeeklyReconciliation",
                "Org admin channel (ID: " # channelId # ") has unexpected name '" #
                channelInfo.name # "' — expected '#" # Constants.ORG_ADMIN_CHANNEL_NAME #
                "'; attempting auto-discovery.",
              );
              switch (await findOrgAdminChannelByName(token)) {
                case (?foundId) {
                  switch (WorkspaceModel.setAdminChannel(workspaces, 0, foundId)) {
                    case (#err(setErr)) {
                      let msg = "Auto-discovery found correctly-named org admin channel (ID: " # foundId # ") but failed to update anchor: " # setErr;
                      Logger.log(#warn, ?"WeeklyReconciliation", msg);
                      List.add(errors, msg);
                      // effectiveChannelId stays as the original (misnamed) channelId
                    };
                    case (#ok()) {
                      orgAdminChannelId := ?foundId;
                      effectiveChannelId := foundId;
                      Logger.log(
                        #info,
                        ?"WeeklyReconciliation",
                        "Auto-anchored org admin channel (ID: " # foundId # ") after detecting old anchor (ID: " # channelId # ") had been renamed.",
                      );
                    };
                  };
                };
                case (null) {
                  // No correctly-named channel found; warn Primary Owner about the rename.
                  switch (findPrimaryOwner(slackUsers.cache)) {
                    case (null) {
                      let msg = "Org admin channel has wrong name ('" # channelInfo.name #
                      "') and Primary Owner not found — cannot send warning DM.";
                      Logger.log(#warn, ?"WeeklyReconciliation", msg);
                      List.add(errors, msg);
                    };
                    case (?ownerId) {
                      let warnText = ":warning: *Looping AI — Org Admin Channel Name Issue*\n\n" #
                      "The org-admin channel (ID: `" # channelId # "`) is currently named " #
                      "`#" # channelInfo.name # "`, but it must be named " #
                      "`#" # Constants.ORG_ADMIN_CHANNEL_NAME # "` for visibility and security best practices.\n\n" #
                      "Please rename the channel to `#" # Constants.ORG_ADMIN_CHANNEL_NAME # "`.";
                      switch (await SlackWrapper.postMessage(token, ownerId, warnText, null, null)) {
                        case (#err(e2)) {
                          let msg = "Failed to DM Primary Owner about org admin channel name issue: " # e2;
                          Logger.log(#error, ?"WeeklyReconciliation", msg);
                          List.add(errors, msg);
                        };
                        case (#ok(_)) {
                          Logger.log(
                            #info,
                            ?"WeeklyReconciliation",
                            "Sent name-warning DM to Primary Owner (" # ownerId # ").",
                          );
                        };
                      };
                    };
                  };
                  await warnIfPublicOrgAdminChannelExists(token, slackUsers.cache);
                };
              };
            };

            // Sync org admin membership from the effective channel (original or auto-discovered).
            switch (await SlackWrapper.getChannelMembers(token, effectiveChannelId)) {
              case (#err(e)) {
                orgAdminChannelOk := false;
                List.add(goneChannels, effectiveChannelId);
                Logger.log(
                  #error,
                  ?"WeeklyReconciliation",
                  "Org admin channel members fetch failed (channelId: " # effectiveChannelId # "): " # e,
                );
                List.add(errors, "Org admin channel members fetch failed: " # e);
              };
              case (#ok(freshMembers)) {
                syncOrgAdminMembership(slackUsers, freshMembers);
              };
            };
          };
        };
      };
    };

    // ---- Step 3: Sync workspace channel anchors ----
    let allWorkspaces = WorkspaceModel.listWorkspaces(workspaces);
    for (ws in allWorkspaces.vals()) {
      workspacesChecked += 1;

      // -- Admin channel for this workspace --
      // Skip workspace 0 — its admin channel is the org-admin channel, already handled in Step 2.
      if (ws.id != 0) {
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
                  switch (orgAdminChannelId) {
                    case (null) {
                      Logger.log(
                        #warn,
                        ?"WeeklyReconciliation",
                        "No org admin channel configured to notify about gone admin channel " #
                        "for workspace " # Nat.toText(ws.id) # " (" # ws.name # ").",
                      );
                    };
                    case (?orgChanId) {
                      let notifyText = ":warning: *Looping AI — Workspace Admin Channel Issue*\n\n" #
                      "The admin channel for workspace *" # ws.name # "* " #
                      "(ID: `" # adminChanId # "`) is no longer accessible.\n\n" #
                      "Please assign a new admin channel for this workspace, or request workspace deletion.";
                      switch (await SlackWrapper.postMessage(token, orgChanId, notifyText, null, null)) {
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
                syncWorkspaceChannelMembership(slackUsers, ws.id, freshMembers);
              };
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

    // ---- Step 5: Purge old secret audit log entries ----
    let secretLogsPurged = SecretModel.purgeAllWorkspaceLogs(secrets, Constants.ACCESS_LOG_RETENTION_NS);
    if (secretLogsPurged > 0) {
      Logger.log(
        #info,
        ?"WeeklyReconciliation",
        "Purged " # Nat.toText(secretLogsPurged) # " old secret audit log entries.",
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

    #ok({
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
      secretLogsPurged;
    });
  };
};
