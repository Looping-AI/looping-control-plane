import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Runtime "mo:core/Runtime";
import Types "./types";
import AuthMiddleware "./middleware/auth-middleware";
import AdminModel "./models/admin-model";
import AgentModel "./models/agent-model";
import ConversationModel "./models/conversation-model";
import SlackUserModel "./models/slack-user-model";
import WorkspaceModel "./models/workspace-model";
import SecretModel "./models/secret-model";
import KeyDerivationService "./services/key-derivation-service";
import WorkspaceTalkService "./services/workspace-talk-service";
import WorkspaceAdminOrchestrator "./orchestrators/workspace-admin-orchestrator";
import McpToolRegistry "./tools/mcp-tool-registry";
import ToolTypes "./tools/tool-types";
import Constants "./constants";
import MetricModel "./models/metric-model";
import ValueStreamModel "./models/value-stream-model";
import ObjectiveModel "./models/objective-model";
import HttpCertification "./utilities/http-certification";
import EventStoreModel "./models/event-store-model";
import EventRouter "./events/event-router";
import NormalizedEventTypes "./events/types/normalized-event-types";
import SlackAdapter "./events/slack-adapter";
import Logger "./utilities/logger";
import WeeklyReconciliationService "./services/weekly-reconciliation-service";

persistent actor class OpenOrgBackend(owner : Principal) {
  // ============================================
  // State
  // ============================================

  var orgOwner : Principal = owner;
  var orgAdmins : [Principal] = [owner];
  var conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();
  var adminConversations = Map.fromArray<Nat, List.List<ConversationModel.Message>>([(0, List.empty<ConversationModel.Message>())], Nat.compare);
  var secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>(); // Encrypted secrets per workspace
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys per workspace
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared
  var lastRetentionCleanupTimestamp : Int = Time.now(); // Track last time retention cleanup ran
  var workspaceAdmins = Map.fromArray<Nat, [Principal]>([(0, [owner])], Nat.compare); // Workspace exists only if ID is present here
  var workspaceMembers = Map.fromArray<Nat, [Principal]>([(0, [])], Nat.compare); // Members of each workspace
  var workspaceAgents = Map.fromArray<Nat, AgentModel.WorkspaceAgentsState>([(0, AgentModel.emptyWorkspaceState())], Nat.compare);
  var mcpToolRegistry = McpToolRegistry.empty(); // MCP tools registry (dynamic, runtime configurable)

  // Slack user cache (Slack user ID → SlackUserEntry with org roles and workspace memberships)
  var slackUsers = SlackUserModel.empty();

  // Workspace channel anchors (workspace ID → WorkspaceRecord with admin/member Slack channel IDs)
  var workspaces = WorkspaceModel.emptyState();

  // Org-admin channel anchor (Slack channel whose members are org-level admins)
  var orgAdminChannel : ?WorkspaceModel.OrgAdminChannelAnchor = null;

  // Metrics and Value Streams state (org-level metrics, workspace-scoped value streams and objectives)
  var metricsRegistry = MetricModel.emptyRegistry(); // Org-level metric definitions (nextMetricId, registry)
  var metricDatapoints = MetricModel.emptyDatapoints(); // Datapoints for each metric
  var workspaceValueStreams = Map.fromArray<Nat, ValueStreamModel.WorkspaceValueStreamsState>([(0, ValueStreamModel.emptyWorkspaceState())], Nat.compare);
  var workspaceObjectives = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(0, Map.empty<Nat, ObjectiveModel.ValueStreamObjectivesState>())], Nat.compare);

  // HTTP certification state (skip-certification for query responses)
  var httpCertStore = HttpCertification.initStore();

  // Event store state (Slack events, per-event timer dispatch)
  var eventStore = EventStoreModel.empty();
  var lastProcessedCleanupTimestamp : Int = Time.now(); // Track last time processed events were purged
  var lastWeeklyReconciliationTimestamp : Int = Time.now(); // Track last time weekly reconciliation ran

  // ============================================
  // Auth Helper
  // ============================================

  private func authContext(caller : Principal, workspaceId : ?Nat) : AuthMiddleware.AuthContext {
    {
      caller;
      workspaceId;
      orgOwner;
      orgAdmins;
      workspaceAdmins;
      workspaceMembers;
    };
  };

  // ============================================
  // Timer Management
  // ============================================

  // Clear Cache Timer function
  private func clearKeyCacheTimer() : async () {
    keyCache := KeyDerivationService.clearCache();
    lastClearTimestamp := Time.now();

    // Start the regular recurring timer for future intervals
    ignore Timer.recurringTimer<system>(
      #nanoseconds(Constants.THIRTY_DAYS_NS),
      clearKeyCacheTimer,
    );
  };

  // Metric Datapoints Retention Cleanup Timer
  // Runs monthly to purge datapoints older than their metric's retention period
  private func metricRetentionCleanupTimer() : async () {
    ignore MetricModel.purgeOldDatapoints(metricDatapoints, metricsRegistry);
    lastRetentionCleanupTimestamp := Time.now();

    // Start the regular recurring timer for future intervals
    ignore Timer.recurringTimer<system>(
      #nanoseconds(Constants.THIRTY_DAYS_NS),
      metricRetentionCleanupTimer,
    );
  };

  // Register HTTP paths that skip response verification
  private func certifyHttpEndpoints() {
    HttpCertification.certifySkipFallbackPath(httpCertStore, "/");
  };

  // Per-event timer callback factory — returns an async closure that processes one event by ID
  private func makeEventProcessor(eventId : Text) : async () {
    let ctx : EventRouter.EventProcessingContext = {
      secrets;
      keyCache;
      adminConversations;
      mcpToolRegistry;
      workspaceValueStreams;
      workspaceObjectives;
      metricsRegistry;
      metricDatapoints;
      slackUsers;
      workspaces;
    };
    await EventRouter.processSingleEvent(eventStore, eventId, ctx);
  };

  // Processed Events Cleanup Timer
  // Runs every 7 days to:
  //   1. Detect unprocessed events stuck for > 1h and move them to failed
  //   2. Purge old processed events (> 7 days)
  //   3. Purge old failed events (> 30 days)
  private func processedEventsCleanupTimer() : async () {
    // 1. Detect and fail stale unprocessed events (enqueuedAt > 1 hour ago)
    let staleIds = EventStoreModel.failStaleUnprocessed(eventStore);
    if (staleIds.size() > 0) {
      let idList = Array.foldLeft<Text, Text>(
        staleIds,
        "",
        func(acc, id) {
          if (acc == "") id else acc # ", " # id;
        },
      );
      Logger.log(#warn, ?"EventStore", "Failed " # Nat.toText(staleIds.size()) # " stale unprocessed event(s): " # idList);
    };

    // 2. Purge old processed events (> 7 days)
    ignore EventStoreModel.purgeProcessed(eventStore);

    // 3. Purge old failed events (> 30 days)
    ignore EventStoreModel.purgeOldFailed(eventStore);

    lastProcessedCleanupTimestamp := Time.now();

    // Reschedule for next interval
    ignore Timer.recurringTimer<system>(
      #nanoseconds(Constants.SEVEN_DAYS_NS),
      processedEventsCleanupTimer,
    );
  };

  // Weekly Reconciliation Timer
  // Runs every 7 days (aligned with Sunday if the first deployment happens on a Sunday).
  // Performs a full users.list + conversations.members sweep and verifies all tracked
  // channel anchors. Notifies admins / the Primary Owner about any channels that have
  // gone missing since the last run.
  private func weeklyReconciliationTimer() : async () {
    // Resolve the bot token from workspace 0 secrets (global Slack integration secret).
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let workspaceSecrets = Map.get(secrets, Nat.compare, 0);
    switch (SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, #slackBotToken)) {
      case (null) {
        Logger.log(
          #warn,
          ?"WeeklyReconciliation",
          "No Slack bot token found for workspace 0 — skipping weekly reconciliation.",
        );
      };
      case (?token) {
        let summary = await WeeklyReconciliationService.run(
          token,
          slackUsers,
          workspaces,
          orgAdminChannel,
        );
        if (summary.errors.size() > 0) {
          Logger.log(
            #warn,
            ?"WeeklyReconciliation",
            "Reconciliation finished with " # Nat.toText(summary.errors.size()) # " error(s).",
          );
        };
      };
    };

    lastWeeklyReconciliationTimestamp := Time.now();

    // Reschedule for next interval
    ignore Timer.recurringTimer<system>(
      #nanoseconds(Constants.SEVEN_DAYS_NS),
      weeklyReconciliationTimer,
    );
  };

  // ============================================
  // Canister Init and Postupgrade
  // ============================================

  // Certify HTTP endpoints on first install
  certifyHttpEndpoints();

  // This logic runs only on the VERY FIRST installation (init)
  // Subsequent upgrades will wipe this timer and it won't be replaced
  let _initTimer = Timer.setTimer<system>(
    #nanoseconds(Constants.THIRTY_DAYS_NS),
    clearKeyCacheTimer,
  );

  // This logic runs only on the VERY FIRST installation (init)
  // Subsequent upgrades will wipe this timer and it won't be replaced
  let _retentionTimer = Timer.setTimer<system>(
    #nanoseconds(Constants.THIRTY_DAYS_NS),
    metricRetentionCleanupTimer,
  );

  // This logic runs only on the VERY FIRST installation (init)
  // Subsequent upgrades will wipe this timer and it won't be replaced
  let _processedCleanupTimer = Timer.setTimer<system>(
    #nanoseconds(Constants.SEVEN_DAYS_NS),
    processedEventsCleanupTimer,
  );

  // This logic runs only on the VERY FIRST installation (init)
  // Subsequent upgrades will wipe this timer and it won't be replaced
  let _weeklyReconciliationTimer = Timer.setTimer<system>(
    #nanoseconds(Constants.SEVEN_DAYS_NS),
    weeklyReconciliationTimer,
  );

  // System hook called after every upgrade
  system func postupgrade() {
    let now = Time.now();

    // Restart cache clearing timer with remaining time
    let cacheElapsed = now - lastClearTimestamp;
    let cacheDelay : Nat = if (cacheElapsed >= Constants.THIRTY_DAYS_NS) {
      0;
    } else {
      Nat.fromInt(Constants.THIRTY_DAYS_NS - cacheElapsed);
    };
    ignore Timer.setTimer<system>(#nanoseconds(cacheDelay), clearKeyCacheTimer);

    // Restart retention cleanup timer with remaining time
    let retentionElapsed = now - lastRetentionCleanupTimestamp;
    let retentionDelay : Nat = if (retentionElapsed >= Constants.THIRTY_DAYS_NS) {
      0;
    } else {
      Nat.fromInt(Constants.THIRTY_DAYS_NS - retentionElapsed);
    };
    ignore Timer.setTimer<system>(#nanoseconds(retentionDelay), metricRetentionCleanupTimer);

    // Restart processed events cleanup timer with remaining time
    let cleanupElapsed = now - lastProcessedCleanupTimestamp;
    let cleanupDelay : Nat = if (cleanupElapsed >= Constants.SEVEN_DAYS_NS) {
      0;
    } else {
      Nat.fromInt(Constants.SEVEN_DAYS_NS - cleanupElapsed);
    };
    ignore Timer.setTimer<system>(#nanoseconds(cleanupDelay), processedEventsCleanupTimer);

    // Restart weekly reconciliation timer with remaining time
    let reconciliationElapsed = now - lastWeeklyReconciliationTimestamp;
    let reconciliationDelay : Nat = if (reconciliationElapsed >= Constants.SEVEN_DAYS_NS) {
      0;
    } else {
      Nat.fromInt(Constants.SEVEN_DAYS_NS - reconciliationElapsed);
    };
    ignore Timer.setTimer<system>(#nanoseconds(reconciliationDelay), weeklyReconciliationTimer);

    // Re-certify HTTP endpoints (IC clears CertifiedData on upgrade)
    // Start from empty store to ensure consistency if paths changed in certifyHttpEndpoints()
    httpCertStore := HttpCertification.initStore();
    certifyHttpEndpoints();
  };

  // ============================================
  // OrgAdmin Management
  // ============================================

  // Add a new organization admin
  public shared ({ caller }) func addOrgAdmin(newAdmin : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        // Business validation
        let validation = AdminModel.validateNewAdmin(newAdmin, orgAdmins);
        switch (validation) {
          case (#err(msg)) { #err(msg) };
          case (#ok(())) {
            orgAdmins := AdminModel.addAdminToList(newAdmin, orgAdmins);
            #ok(());
          };
        };
      };
    };
  };

  // Get list of organization admins
  public query func getOrgAdmins() : async [Principal] {
    orgAdmins;
  };

  // Check if caller is an organization admin
  public shared ({ caller }) func isCallerOrgAdmin() : async Bool {
    AdminModel.isAdmin(caller, orgAdmins);
  };

  // Add a new workspace admin
  public shared ({ caller }) func addWorkspaceAdmin(workspaceId : Nat, newAdmin : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAdmins, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?admins) {
            // Business validation
            let validation = AdminModel.validateNewAdmin(newAdmin, admins);
            switch (validation) {
              case (#err(msg)) { #err(msg) };
              case (#ok(())) {
                let newAdmins = AdminModel.addAdminToList(newAdmin, admins);
                Map.add(workspaceAdmins, Nat.compare, workspaceId, newAdmins);
                #ok(());
              };
            };
          };
        };
      };
    };
  };

  // Add a new workspace member
  public shared ({ caller }) func addWorkspaceMember(workspaceId : Nat, newMember : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?members) {
            // Business validation
            let validation = AdminModel.validateNewMember(newMember, members);
            switch (validation) {
              case (#err(msg)) { #err(msg) };
              case (#ok(())) {
                let newMembers = AdminModel.addMemberToList(newMember, members);
                Map.add(workspaceMembers, Nat.compare, workspaceId, newMembers);
                #ok(());
              };
            };
          };
        };
      };
    };
  };

  // Get workspace members (only workspace admins can view)
  public shared ({ caller }) func getWorkspaceMembers(workspaceId : Nat) : async {
    #ok : [Principal];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin, #IsWorkspaceMember])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?members) { #ok(members) };
        };
      };
    };
  };

  // Check if caller is a workspace member
  public shared ({ caller }) func isCallerWorkspaceMember(workspaceId : Nat) : async Bool {
    switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
      case (null) { false };
      case (?members) { AdminModel.isMember(caller, members) };
    };
  };

  // ============================================
  // Workspace Channel-Anchor Management (Phase 0.5)
  // ============================================

  // Create a new workspace (org admin or org owner only).
  // Initialises all per-workspace maps so the workspace is immediately usable.
  public shared ({ caller }) func createWorkspace(name : Text) : async {
    #ok : Nat;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (WorkspaceModel.createWorkspace(workspaces, name)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(wsId)) {
            // Seed all per-workspace maps so existing guards ("workspace not found") pass.
            // The caller is seeded as the initial workspace admin.
            Map.add(workspaceAdmins, Nat.compare, wsId, [caller]);
            Map.add(workspaceMembers, Nat.compare, wsId, []);
            Map.add(workspaceAgents, Nat.compare, wsId, AgentModel.emptyWorkspaceState());
            Map.add(workspaceValueStreams, Nat.compare, wsId, ValueStreamModel.emptyWorkspaceState());
            Map.add(workspaceObjectives, Nat.compare, wsId, Map.empty<Nat, ObjectiveModel.ValueStreamObjectivesState>());
            Map.add(adminConversations, Nat.compare, wsId, List.empty<ConversationModel.Message>());
            #ok(wsId);
          };
        };
      };
    };
  };

  // Get a workspace record by ID (any authenticated caller).
  public shared ({ caller }) func getWorkspace(workspaceId : Nat) : async {
    #ok : ?WorkspaceModel.WorkspaceRecord;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok(WorkspaceModel.getWorkspace(workspaces, workspaceId));
      };
    };
  };

  // List all workspace records (org admin or org owner).
  public shared ({ caller }) func listWorkspaces() : async {
    #ok : [WorkspaceModel.WorkspaceRecord];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok(WorkspaceModel.listWorkspaces(workspaces));
      };
    };
  };

  // Set the admin channel anchor for a workspace.
  // Members of this Slack channel will be granted workspace admin scope.
  public shared ({ caller }) func setWorkspaceAdminChannel(workspaceId : Nat, channelId : Text) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        WorkspaceModel.setAdminChannel(workspaces, workspaceId, channelId);
      };
    };
  };

  // Set the member channel anchor for a workspace.
  // Members of this Slack channel will be granted workspace member scope.
  public shared ({ caller }) func setWorkspaceMemberChannel(workspaceId : Nat, channelId : Text) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        WorkspaceModel.setMemberChannel(workspaces, workspaceId, channelId);
      };
    };
  };

  // Set the org-admin channel anchor (org owner only).
  // Members of this channel are treated as org-level admins.
  public shared ({ caller }) func setOrgAdminChannel(channelId : Text, channelName : Text) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        orgAdminChannel := ?{ channelId; channelName };
        #ok(());
      };
    };
  };

  // Get the current org-admin channel anchor (public query — channel IDs are not secret).
  public query func getOrgAdminChannel() : async ?WorkspaceModel.OrgAdminChannelAnchor {
    orgAdminChannel;
  };

  // ============================================
  // Agent Management
  // ============================================

  // Create a new agent
  public shared ({ caller }) func createAgent(workspaceId : Nat, name : Text, provider : Types.LlmProvider, model : Text) : async {
    #ok : Nat;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?workspaceState) {
            AgentModel.createAgent(name, provider, model, workspaceState);
          };
        };
      };
    };
  };

  // Read/Get an agent
  public shared ({ caller }) func getAgent(workspaceId : Nat, id : Nat) : async {
    #ok : ?AgentModel.Agent;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin, #IsWorkspaceMember])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?workspaceState) {
            #ok(AgentModel.getAgent(id, workspaceState));
          };
        };
      };
    };
  };

  // Update an agent
  public shared ({ caller }) func updateAgent(workspaceId : Nat, id : Nat, newName : ?Text, newProvider : ?Types.LlmProvider, newModel : ?Text) : async {
    #ok : Bool;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?workspaceState) {
            AgentModel.updateAgent(id, newName, newProvider, newModel, workspaceState);
          };
        };
      };
    };
  };

  // Delete an agent
  public shared ({ caller }) func deleteAgent(workspaceId : Nat, id : Nat) : async {
    #ok : Bool;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?workspaceState) { AgentModel.deleteAgent(id, workspaceState) };
        };
      };
    };
  };

  // List all agents
  public shared ({ caller }) func listAgents(workspaceId : Nat) : async {
    #ok : [AgentModel.Agent];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin, #IsWorkspaceMember])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found.") };
          case (?workspaceState) { #ok(AgentModel.listAgents(workspaceState)) };
        };
      };
    };
  };

  // ============================================
  // Conversation Management
  // ============================================

  // Get workspace -> agent conversation history
  public shared ({ caller }) func getConversation(workspaceId : Nat, agentId : Nat) : async {
    #ok : [ConversationModel.Message];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin, #IsWorkspaceMember])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ConversationModel.getConversation(conversations, workspaceId, agentId);
      };
    };
  };

  // Get workspace admin conversation history
  public shared ({ caller }) func getAdminConversation(workspaceId : Nat) : async {
    #ok : [ConversationModel.Message];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ConversationModel.getAdminConversation(adminConversations, workspaceId);
      };
    };
  };

  // ============================================
  // MCP Tool Management
  // ============================================

  // Register a new MCP tool
  // Only org owner and org admins can register MCP tools
  public shared ({ caller }) func registerMcpTool(tool : ToolTypes.McpToolRegistration) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (McpToolRegistry.register(mcpToolRegistry, tool)) {
          case (#ok) { #ok(()) };
          case (#err(msg)) { #err(msg) };
        };
      };
    };
  };

  // Unregister an MCP tool by name
  // Only org owner and org admins can unregister MCP tools
  public shared ({ caller }) func unregisterMcpTool(toolName : Text) : async {
    #ok : Bool;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let removed = McpToolRegistry.unregister(mcpToolRegistry, toolName);
        #ok(removed);
      };
    };
  };

  // Get all registered MCP tools
  // Only org owner and org admins can view MCP tools
  public shared ({ caller }) func listMcpTools() : async {
    #ok : [ToolTypes.McpToolRegistration];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok(McpToolRegistry.getAll(mcpToolRegistry));
      };
    };
  };

  // ============================================
  // Workspace Admin Talk
  // ============================================

  public shared ({ caller }) func workspaceAdminTalk(workspaceId : Nat, message : Text) : async {
    #ok : {
      messages : [ConversationModel.Message];
      steps : [Types.ProcessingStep];
    };
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (Text.trim(message, #char ' ') == "") {
          return #err("Message cannot be empty.");
        };
        // Extract workspace-specific data
        let workspaceValueStreamsState = switch (Map.get(workspaceValueStreams, Nat.compare, workspaceId)) {
          case (null) { return #err("Workspace value streams not found.") };
          case (?state) { state };
        };
        let workspaceObjectivesMap = switch (Map.get(workspaceObjectives, Nat.compare, workspaceId)) {
          case (null) { return #err("Workspace objectives not found.") };
          case (?objMap) { objMap };
        };
        // Scope secrets and conversation history to the workspace
        let workspaceSecrets = Map.get(secrets, Nat.compare, workspaceId);
        let workspaceConversations = switch (Map.get(adminConversations, Nat.compare, workspaceId)) {
          case (?list) { list };
          case (null) {
            // First message in this workspace — create the entry so mutations persist
            let newList = List.empty<ConversationModel.Message>();
            Map.add(adminConversations, Nat.compare, workspaceId, newList);
            newList;
          };
        };

        // Derive encryption key for this workspace (once, shared to orchestrator)
        let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);

        // Delegate to orchestrator for business logic
        let orchestratorResult = await WorkspaceAdminOrchestrator.orchestrateAdminTalk(
          mcpToolRegistry,
          workspaceSecrets,
          workspaceConversations,
          workspaceValueStreamsState,
          workspaceValueStreams,
          workspaceObjectivesMap,
          metricsRegistry,
          metricDatapoints,
          workspaceId,
          message,
          encryptionKey,
        );
        // Return messages and steps to the caller
        switch (orchestratorResult) {
          case (#ok({ messages; steps })) { #ok({ messages; steps }) };
          case (#err(e)) { #err(e) };
        };
      };
    };
  };

  // ============================================
  // Workspace Talk
  // ============================================

  public shared ({ caller }) func workspaceTalk(workspaceId : Nat, agentId : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin, #IsWorkspaceMember])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (Text.trim(message, #char ' ') == "") {
          return #err("Message cannot be empty.");
        };
        // Delegate to service for business logic
        await WorkspaceTalkService.processWorkspaceTalk(
          workspaceAgents,
          secrets,
          conversations,
          workspaceId,
          agentId,
          message,
          keyCache,
        );
      };
    };
  };

  // ============================================
  // Secrets Management
  // ============================================

  // Store a secret in a workspace (encrypted at rest)
  // Workspace admins can store LLM API keys; org owner/admins can store integration secrets
  public shared ({ caller }) func storeSecret(workspaceId : Nat, secretId : Types.SecretId, secret : Text) : async {
    #ok : ();
    #err : Text;
  } {
    // Integration secrets (Slack) require org-level auth; LLM keys require workspace admin
    let requiredRoles = switch (secretId) {
      case (#slackSigningSecret or #slackBotToken) {
        [#IsOrgOwner, #IsOrgAdmin];
      };
      case (#groqApiKey or #openaiApiKey) {
        [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin];
      };
    };
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), requiredRoles)) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (Text.trim(secret, #char ' ') == "") {
          return #err("Secret cannot be empty.");
        };
        // Verify workspace exists
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { return #err("Workspace not found.") };
          case (?_) {};
        };

        // Derive encryption key for this workspace
        let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);

        SecretModel.storeSecret(secrets, encryptionKey, workspaceId, secretId, secret);
      };
    };
  };

  // Get stored secret identifiers for a workspace (does not return the secret values)
  // Only workspace admins can view stored secrets
  public shared ({ caller }) func getWorkspaceSecrets(workspaceId : Nat) : async {
    #ok : [Types.SecretId];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        SecretModel.getWorkspaceSecrets(secrets, workspaceId);
      };
    };
  };

  // Delete a secret for a specific secret ID in a workspace
  // Workspace admins can delete LLM API keys; org owner/admins can delete integration secrets
  public shared ({ caller }) func deleteSecret(workspaceId : Nat, secretId : Types.SecretId) : async {
    #ok : ();
    #err : Text;
  } {
    let requiredRoles = switch (secretId) {
      case (#slackSigningSecret or #slackBotToken) {
        [#IsOrgOwner, #IsOrgAdmin];
      };
      case (#groqApiKey or #openaiApiKey) {
        [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin];
      };
    };
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), requiredRoles)) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        SecretModel.deleteSecret(secrets, workspaceId, secretId);
      };
    };
  };

  // ============================================
  // Key Cache Management
  // ============================================

  // Manually clear the key cache (admin only)
  public shared ({ caller }) func clearKeyCache() : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        keyCache := KeyDerivationService.clearCache();
        #ok(());
      };
    };
  };

  // Get cache statistics (admin only)
  public shared ({ caller }) func getKeyCacheStats() : async {
    #ok : { size : Nat };
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok({ size = KeyDerivationService.getCacheSize(keyCache) });
      };
    };
  };

  // ============================================
  // Metrics API (Org-Level)
  // ============================================

  /// Register a new metric
  public shared ({ caller }) func registerMetric(input : MetricModel.MetricRegistrationInput) : async {
    #ok : MetricModel.MetricRegistration;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let result = MetricModel.registerMetric(
          metricsRegistry,
          input,
          caller,
          Time.now(),
        );
        switch (result) {
          case (#err(msg)) { #err(msg) };
          case (#ok(id)) {
            switch (MetricModel.getMetric(metricsRegistry, id)) {
              case (null) { #err("Failed to retrieve registered metric.") };
              case (?metric) { #ok(metric) };
            };
          };
        };
      };
    };
  };

  /// Get a metric by ID
  public shared ({ caller }) func getMetric(metricId : Nat) : async {
    #ok : MetricModel.MetricRegistration;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (MetricModel.getMetric(metricsRegistry, metricId)) {
          case (null) { #err("Metric not found.") };
          case (?metric) { #ok(metric) };
        };
      };
    };
  };

  /// List all registered metrics
  public shared ({ caller }) func listMetrics() : async {
    #ok : [MetricModel.MetricRegistration];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok(MetricModel.listMetrics(metricsRegistry));
      };
    };
  };

  /// Record a datapoint for a metric
  public shared ({ caller }) func recordMetricDatapoint(
    metricId : Nat,
    value : Float,
    source : MetricModel.MetricSource,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        MetricModel.recordDatapoint(
          metricDatapoints,
          metricsRegistry,
          metricId,
          value,
          source,
          Time.now(),
        );
      };
    };
  };

  /// Get datapoints for a metric
  public shared ({ caller }) func getMetricDatapoints(metricId : Nat, since : ?Int) : async {
    #ok : [MetricModel.MetricDatapoint];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (MetricModel.getMetric(metricsRegistry, metricId)) {
          case (null) { #err("Metric not found.") };
          case (?_) {
            #ok(MetricModel.getDatapoints(metricDatapoints, metricId, since));
          };
        };
      };
    };
  };

  /// Get the latest datapoint for a metric
  public shared ({ caller }) func getLatestMetricDatapoint(metricId : Nat) : async {
    #ok : ?MetricModel.MetricDatapoint;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (MetricModel.getMetric(metricsRegistry, metricId)) {
          case (null) { #err("Metric not found.") };
          case (?_) {
            #ok(MetricModel.getLatestDatapoint(metricDatapoints, metricId));
          };
        };
      };
    };
  };

  /// Unregister a metric and delete all its datapoints
  public shared ({ caller }) func unregisterMetric(metricId : Nat) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (MetricModel.unregisterMetric(metricsRegistry, metricDatapoints, metricId)) {
          #ok(());
        } else {
          #err("Metric not found.");
        };
      };
    };
  };

  /// Purge old metric datapoints based on retention settings
  /// Returns the number of datapoints purged
  public shared ({ caller }) func purgeOldMetricDatapoints() : async {
    #ok : { purged : Nat; sizeBefore : Nat; sizeAfter : Nat };
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let sizeBefore = MetricModel.totalDatapointsCount(metricDatapoints);
        ignore MetricModel.purgeOldDatapoints(metricDatapoints, metricsRegistry);
        let sizeAfter = MetricModel.totalDatapointsCount(metricDatapoints);
        #ok({ purged = sizeBefore - sizeAfter; sizeBefore; sizeAfter });
      };
    };
  };

  // ============================================
  // Value Streams API (Workspace-Scoped)
  // ============================================

  /// Create a new value stream in a workspace
  public shared ({ caller }) func createValueStream(
    workspaceId : Nat,
    input : ValueStreamModel.ValueStreamInput,
  ) : async {
    #ok : ValueStreamModel.ShareableValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.createValueStream(workspaceValueStreams, workspaceId, input)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(id)) {
            switch (ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, id)) {
              case (#err(msg)) { #err(msg) };
              case (#ok(vs)) { #ok(ValueStreamModel.toShareable(vs)) };
            };
          };
        };
      };
    };
  };

  /// Get a value stream by ID
  public shared ({ caller }) func getValueStream(
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : async {
    #ok : ValueStreamModel.ShareableValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, valueStreamId)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(vs)) { #ok(ValueStreamModel.toShareable(vs)) };
        };
      };
    };
  };

  /// List all value streams in a workspace
  public shared ({ caller }) func listValueStreams(workspaceId : Nat) : async {
    #ok : [ValueStreamModel.ShareableValueStream];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.listValueStreams(workspaceValueStreams, workspaceId)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(streams)) {
            #ok(
              Array.map<ValueStreamModel.ValueStream, ValueStreamModel.ShareableValueStream>(
                streams,
                ValueStreamModel.toShareable,
              )
            );
          };
        };
      };
    };
  };

  /// Update a value stream
  public shared ({ caller }) func updateValueStream(
    workspaceId : Nat,
    valueStreamId : Nat,
    newName : ?Text,
    newProblem : ?Text,
    newGoal : ?Text,
    newStatus : ?ValueStreamModel.ValueStreamStatus,
  ) : async {
    #ok : ValueStreamModel.ShareableValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.updateValueStream(workspaceValueStreams, workspaceId, valueStreamId, newName, newProblem, newGoal, newStatus)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(())) {
            switch (ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, valueStreamId)) {
              case (#err(msg)) { #err(msg) };
              case (#ok(vs)) { #ok(ValueStreamModel.toShareable(vs)) };
            };
          };
        };
      };
    };
  };

  /// Delete a value stream
  public shared ({ caller }) func deleteValueStream(
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        // Also delete objectives for this value stream
        ObjectiveModel.deleteValueStreamObjectives(workspaceObjectives, workspaceId, valueStreamId);
        ValueStreamModel.deleteValueStream(workspaceValueStreams, workspaceId, valueStreamId);
      };
    };
  };

  /// Set or update the plan for a value stream
  public shared ({ caller }) func setValueStreamPlan(
    workspaceId : Nat,
    valueStreamId : Nat,
    input : ValueStreamModel.PlanInput,
    diff : Text,
  ) : async {
    #ok : ValueStreamModel.ShareableValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let author : ValueStreamModel.PlanChangeAuthor = #principal(caller);
        switch (ValueStreamModel.setPlan(workspaceValueStreams, workspaceId, valueStreamId, input, author, diff)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(())) {
            switch (ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, valueStreamId)) {
              case (#err(msg)) { #err(msg) };
              case (#ok(vs)) { #ok(ValueStreamModel.toShareable(vs)) };
            };
          };
        };
      };
    };
  };

  // ============================================
  // Objectives API (Workspace-Scoped, within Value Streams)
  // ============================================

  /// Add an objective to a value stream
  public shared ({ caller }) func addObjective(
    workspaceId : Nat,
    valueStreamId : Nat,
    input : ObjectiveModel.ObjectiveInput,
  ) : async {
    #ok : ObjectiveModel.ShareableObjective;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        // Initialize objectives state for value stream if not exists
        ObjectiveModel.initValueStreamObjectives(workspaceObjectives, workspaceId, valueStreamId);
        switch (ObjectiveModel.addObjective(workspaceObjectives, workspaceId, valueStreamId, input)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(id)) {
            switch (ObjectiveModel.getObjective(workspaceObjectives, workspaceId, valueStreamId, id)) {
              case (#err(msg)) { #err(msg) };
              case (#ok(obj)) { #ok(ObjectiveModel.toShareable(obj)) };
            };
          };
        };
      };
    };
  };

  /// Get an objective by ID
  public shared ({ caller }) func getObjective(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : async {
    #ok : ObjectiveModel.ShareableObjective;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ObjectiveModel.getObjective(workspaceObjectives, workspaceId, valueStreamId, objectiveId)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(obj)) { #ok(ObjectiveModel.toShareable(obj)) };
        };
      };
    };
  };

  /// List all objectives for a value stream
  public shared ({ caller }) func listObjectives(
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : async {
    #ok : [ObjectiveModel.ShareableObjective];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        // Initialize objectives state for value stream if not exists
        ObjectiveModel.initValueStreamObjectives(workspaceObjectives, workspaceId, valueStreamId);
        switch (ObjectiveModel.listObjectives(workspaceObjectives, workspaceId, valueStreamId)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(objs)) {
            #ok(Array.map<ObjectiveModel.Objective, ObjectiveModel.ShareableObjective>(objs, ObjectiveModel.toShareable));
          };
        };
      };
    };
  };

  /// Update an objective
  public shared ({ caller }) func updateObjective(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    newName : ?Text,
    newDescription : ??Text,
    newObjectiveType : ?ObjectiveModel.ObjectiveType,
    newMetricIds : ?[Nat],
    newComputation : ?Text,
    newTarget : ?ObjectiveModel.ObjectiveTarget,
    newTargetDate : ??Int,
    newStatus : ?ObjectiveModel.ObjectiveStatus,
  ) : async {
    #ok : ObjectiveModel.ShareableObjective;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ObjectiveModel.updateObjective(workspaceObjectives, workspaceId, valueStreamId, objectiveId, newName, newDescription, newObjectiveType, newMetricIds, newComputation, newTarget, newTargetDate, newStatus)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(())) {
            switch (ObjectiveModel.getObjective(workspaceObjectives, workspaceId, valueStreamId, objectiveId)) {
              case (#err(msg)) { #err(msg) };
              case (#ok(obj)) { #ok(ObjectiveModel.toShareable(obj)) };
            };
          };
        };
      };
    };
  };

  /// Archive an objective
  public shared ({ caller }) func archiveObjective(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.archiveObjective(workspaceObjectives, workspaceId, valueStreamId, objectiveId);
      };
    };
  };

  /// Record a datapoint for an objective
  public shared ({ caller }) func recordObjectiveDatapoint(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    datapoint : ObjectiveModel.ObjectiveDatapoint,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.recordObjectiveDatapoint(workspaceObjectives, workspaceId, valueStreamId, objectiveId, datapoint);
      };
    };
  };

  /// Get the history of an objective as an array
  public shared ({ caller }) func getObjectiveHistory(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : async {
    #ok : [ObjectiveModel.ObjectiveDatapoint];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.getHistoryArray(workspaceObjectives, workspaceId, valueStreamId, objectiveId);
      };
    };
  };

  /// Add a comment to a datapoint in an objective's history
  public shared ({ caller }) func addObjectiveDatapointComment(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    historyIndex : Nat,
    comment : ObjectiveModel.ObjectiveDatapointComment,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.addCommentToHistoryDatapoint(workspaceObjectives, workspaceId, valueStreamId, objectiveId, historyIndex, comment);
      };
    };
  };

  /// Add an impact review to an objective
  public shared ({ caller }) func addImpactReview(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    review : ObjectiveModel.ImpactReview,
  ) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.addImpactReview(workspaceObjectives, workspaceId, valueStreamId, objectiveId, review);
      };
    };
  };

  /// Get impact reviews for an objective
  public shared query ({ caller }) func getImpactReviews(
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : async {
    #ok : [ObjectiveModel.ImpactReview];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ObjectiveModel.getImpactReviews(workspaceObjectives, workspaceId, valueStreamId, objectiveId);
      };
    };
  };

  // ============================================
  // HTTP Incoming Requests (Webhooks)
  // ============================================

  // Helper to construct a standard text response
  private func respondWithText(statusCode : Nat16, message : Text) : Types.HttpResponse {
    {
      status_code = statusCode;
      headers = [("content-type", "text/plain")];
      body = Text.encodeUtf8(message);
      upgrade = null;
    };
  };

  // Helper to construct a text response with certification headers
  private func respondWithTextAndCertificate(statusCode : Nat16, message : Text, url : Text) : Types.HttpResponse {
    let certHeaders = HttpCertification.getSkipCertificationHeaders(httpCertStore, url);
    {
      status_code = statusCode;
      headers = Array.concat<(Text, Text)>([("content-type", "text/plain")], certHeaders);
      body = Text.encodeUtf8(message);
      upgrade = null;
    };
  };

  /// Query entry point for all incoming HTTP requests.
  /// POST requests are upgraded to update calls so they can mutate state.
  /// GET requests return a simple status message.
  public query func http_request(req : Types.HttpRequest) : async Types.HttpResponse {
    if (req.method == "POST") {
      {
        status_code = 200;
        headers = [];
        body = Blob.fromArray([]);
        upgrade = ?true;
      };
    } else if (req.method == "GET") {
      respondWithTextAndCertificate(200, "Looping AI API Server", req.url);
    } else {
      respondWithTextAndCertificate(400, "Bad Request", req.url);
    };
  };

  /// Update entry point called when http_request returns upgrade = ?true.
  /// Handles Slack webhook payloads: verifies signature, parses events, enqueues for processing.
  /// Responds immediately (no awaits for LLM calls) to avoid Slack retries.
  public func http_request_update(req : Types.HttpUpdateRequest) : async Types.HttpResponse {
    // Ensure this is a request to the Slack webhook endpoint (accept query parameters)
    if (not (Text.startsWith(req.url, #text "/webhook/slack") or Text.startsWith(req.url, #text "/webhook/slack/"))) {
      return respondWithText(400, "Unrecognized path");
    };

    let bodyText = switch (Text.decodeUtf8(req.body)) {
      case (?text) { text };
      case (null) {
        return respondWithText(400, "Invalid request body encoding");
      };
    };

    // Parse the envelope to determine type
    let envelope = switch (SlackAdapter.parseEnvelope(bodyText)) {
      case (#err(e)) {
        Logger.log(#error, ?"SlackWebhook", "Failed to parse envelope: " # e);
        return respondWithText(400, "Invalid payload. Error: " # e);
      };
      case (#ok(env)) { env };
    };

    // Handle url_verification (challenge handshake) — no signature check needed
    switch (envelope) {
      case (#url_verification(verification)) {
        return respondWithText(200, verification.challenge);
      };
      case _ {};
    };

    // For all other event types, verify the Slack signature
    // Retrieve the signing secret from workspace
    let workspaceId = 0; // TODO: Support multiple workspaces in the future
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let signingSecret = SecretModel.getSecret(secrets, encryptionKey, workspaceId, #slackSigningSecret);

    switch (signingSecret) {
      case (null) {
        Logger.log(#error, ?"SlackWebhook", "No signing secret configured for workspace " # Nat.toText(workspaceId));
        return respondWithText(401, "Slack signing secret not configured");
      };
      case (?secret) {
        let signature = switch (SlackAdapter.getHeader(req.headers, "X-Slack-Signature")) {
          case (null) {
            return respondWithText(401, "Missing signature");
          };
          case (?sig) { sig };
        };
        let timestamp = switch (SlackAdapter.getHeader(req.headers, "X-Slack-Request-Timestamp")) {
          case (null) {
            return respondWithText(401, "Missing timestamp");
          };
          case (?ts) { ts };
        };

        if (not SlackAdapter.verifySignature(secret, signature, timestamp, bodyText)) {
          Logger.log(#warn, ?"SlackWebhook", "Signature verification failed");
          return respondWithText(401, "Invalid signature");
        };
      };
    };

    // Signature verified — process the envelope
    switch (envelope) {
      case (#url_verification(_)) {
        Runtime.unreachable(); // handled before and returned
      };
      case (#event_callback(callback)) {
        // Normalize and enqueue the event
        switch (SlackAdapter.normalizeEvent(callback)) {
          case (#err(reason)) {
            Logger.log(#_debug, ?"SlackWebhook", "Skipping event: " # reason);
            // Still return 200 so Slack doesn't retry
            respondWithText(200, "ok");
          };
          case (#ok(event)) {
            switch (EventStoreModel.enqueue(eventStore, event)) {
              case (#duplicate) {
                Logger.log(#_debug, ?"EventStore", "Duplicate event: " # event.eventId);
              };
              case (#ok) {
                Logger.log(#_debug, ?"EventStore", "Enqueued event: " # event.eventId);
                // Schedule a per-event timer to process immediately
                let eid = event.eventId;
                ignore Timer.setTimer<system>(
                  #seconds 0,
                  func() : async () {
                    await makeEventProcessor(eid);
                  },
                );
              };
            };
            respondWithText(200, "ok");
          };
        };
      };
      case (#app_rate_limited(rateLimited)) {
        let minuteStr = Int.toText(rateLimited.minute_rate_limited);
        let logMsg = "Rate-limiting events for team " # rateLimited.team_id # " at minute " # minuteStr;
        Logger.log(#warn, ?"SlackWebhook", logMsg);
        respondWithText(200, "ok");
      };
      case (#unknown(envelopeType)) {
        Logger.log(#warn, ?"SlackWebhook", "Unknown envelope type: " # envelopeType);
        respondWithText(200, "ok");
      };
    };
  };

  // ============================================
  // Event Queue Stats & Management (Admin)
  // ============================================

  /// Get event queue statistics (admin only)
  public shared ({ caller }) func getEventStoreStats() : async {
    #ok : { unprocessedEvents : Nat; processedEvents : Nat; failedEvents : Nat };
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let stats = EventStoreModel.sizes(eventStore);
        #ok({
          unprocessedEvents = stats.unprocessed;
          processedEvents = stats.processed;
          failedEvents = stats.failed;
        });
      };
    };
  };

  /// Get all failed events (admin only)
  public shared ({ caller }) func getFailedEvents() : async {
    #ok : [NormalizedEventTypes.Event];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        #ok(EventStoreModel.listFailed(eventStore));
      };
    };
  };

  /// Delete failed event(s) — null deletes all, ?id deletes specific
  public shared ({ caller }) func deleteFailedEvents(eventId : ?Text) : async {
    #ok : { deleted : Nat };
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let deleted = EventStoreModel.deleteFailed(eventStore, eventId);
        #ok({ deleted });
      };
    };
  };
};
