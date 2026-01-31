import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Types "./types";
import AuthMiddleware "./middleware/auth-middleware";
import AdminModel "./models/admin-model";
import AgentModel "./models/agent-model";
import ConversationModel "./models/conversation-model";
import ApiKeysModel "./models/api-keys-model";
import KeyDerivationService "./services/key-derivation-service";
import WorkspaceTalkService "./services/workspace-talk-service";
import WorkspaceAdminOrchestrator "./orchestrators/workspace-admin-orchestrator";
import McpToolRegistry "./tools/mcp-tool-registry";
import ToolTypes "./tools/tool-types";
import Constants "./constants";
import MetricModel "./models/metric-model";
import ValueStreamModel "./models/value-stream-model";
import ObjectiveModel "./models/objective-model";

persistent actor class OpenOrgBackend(owner : Principal) {
  // ============================================
  // State
  // ============================================

  var orgOwner : Principal = owner;
  var orgAdmins : [Principal] = [owner];
  var conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();
  var adminConversations = Map.fromArray<Nat, List.List<ConversationModel.Message>>([(0, List.empty<ConversationModel.Message>())], Nat.compare);
  var apiKeys = Map.empty<Nat, Map.Map<Types.LlmProvider, ApiKeysModel.EncryptedApiKey>>(); // Encrypted API keys per workspace
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys per workspace
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared
  var lastRetentionCleanupTimestamp : Int = Time.now(); // Track last time retention cleanup ran
  var workspaceAdmins = Map.fromArray<Nat, [Principal]>([(0, [owner])], Nat.compare); // Workspace exists only if ID is present here
  var workspaceMembers = Map.fromArray<Nat, [Principal]>([(0, [])], Nat.compare); // Members of each workspace
  var nextAgentId : Nat = 0;
  var workspaceAgents = Map.fromArray<Nat, Map.Map<Nat, AgentModel.Agent>>([(0, Map.empty<Nat, AgentModel.Agent>())], Nat.compare);
  var mcpToolRegistry = McpToolRegistry.empty(); // MCP tools registry (dynamic, runtime configurable)

  // Metrics and Value Streams state (org-level metrics, workspace-scoped value streams and objectives)
  var metricsRegistry = MetricModel.emptyRegistry(); // Org-level metric definitions
  var nextMetricId : Nat = 0;
  var metricDatapoints = MetricModel.emptyDatapoints(); // Datapoints for each metric
  var workspaceValueStreams = Map.fromArray<Nat, ValueStreamModel.WorkspaceValueStreamsState>([(0, ValueStreamModel.emptyWorkspaceState())], Nat.compare);
  var workspaceObjectives = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(0, Map.empty<Nat, ObjectiveModel.ValueStreamObjectivesState>())], Nat.compare);

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

  // System hook called after every upgrade
  system func postupgrade() {
    let now = Time.now();

    // Restart cache clearing timer with remaining time
    let cacheElapsed = now - lastClearTimestamp;
    let cacheRemaining = Constants.THIRTY_DAYS_NS - cacheElapsed;
    ignore Timer.setTimer<system>(#nanoseconds(Int.abs(cacheRemaining)), clearKeyCacheTimer);

    // Restart retention cleanup timer with remaining time
    let retentionElapsed = now - lastRetentionCleanupTimestamp;
    let retentionRemaining = Constants.THIRTY_DAYS_NS - retentionElapsed;
    ignore Timer.setTimer<system>(#nanoseconds(Int.abs(retentionRemaining)), metricRetentionCleanupTimer);
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
          case (?agents) {
            let (result, newId) = AgentModel.createAgent(name, provider, model, agents, nextAgentId);
            nextAgentId := newId;
            result;
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
          case (?agents) { #ok(AgentModel.getAgent(id, agents)) };
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
          case (?agents) {
            AgentModel.updateAgent(id, newName, newProvider, newModel, agents);
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
          case (?agents) { AgentModel.deleteAgent(id, agents) };
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
          case (?agents) { #ok(AgentModel.listAgents(agents)) };
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    #ok : Text;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (Text.trim(message, #char ' ') == "") {
          return #err("Message cannot be empty.");
        };
        // Delegate to orchestrator for business logic
        await WorkspaceAdminOrchestrator.orchestrateAdminTalk(
          mcpToolRegistry,
          apiKeys,
          adminConversations,
          workspaceId,
          message,
          keyCache,
        );
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
          apiKeys,
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
  // API Key Management
  // ============================================

  // Store an API key for a provider in a workspace (encrypted at rest)
  // Only workspace admins can store API keys
  public shared ({ caller }) func storeApiKey(workspaceId : Nat, provider : Types.LlmProvider, apiKey : Text) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (Text.trim(apiKey, #char ' ') == "") {
          return #err("API key cannot be empty.");
        };
        // Verify workspace exists
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { return #err("Workspace not found.") };
          case (?_) {};
        };

        // Derive encryption key for this workspace
        let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);

        ApiKeysModel.storeApiKey(apiKeys, encryptionKey, workspaceId, provider, apiKey);
      };
    };
  };

  // Get API keys for a workspace
  // Only workspace admins can view API keys
  public shared ({ caller }) func getWorkspaceApiKeys(workspaceId : Nat) : async {
    #ok : [Types.LlmProvider];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ApiKeysModel.getWorkspaceApiKeys(apiKeys, workspaceId);
      };
    };
  };

  // Delete an API key for a specific provider in a workspace
  // Only workspace admins can delete API keys
  public shared ({ caller }) func deleteApiKey(workspaceId : Nat, provider : Types.LlmProvider) : async {
    #ok : ();
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ApiKeysModel.deleteApiKey(apiKeys, workspaceId, provider);
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        let (result, newNextId) = MetricModel.registerMetric(
          metricsRegistry,
          nextMetricId,
          input,
          caller,
          Time.now(),
        );
        switch (result) {
          case (#err(msg)) { #err(msg) };
          case (#ok(id)) {
            nextMetricId := newNextId;
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    switch (AuthMiddleware.authorize(authContext(caller, null), [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin])) {
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
    #ok : ValueStreamModel.ValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.createValueStream(workspaceValueStreams, workspaceId, input)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(id)) {
            ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, id);
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
    #ok : ValueStreamModel.ValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, valueStreamId);
      };
    };
  };

  /// List all value streams in a workspace
  public shared ({ caller }) func listValueStreams(workspaceId : Nat) : async {
    #ok : [ValueStreamModel.ValueStream];
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        ValueStreamModel.listValueStreams(workspaceValueStreams, workspaceId);
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
    #ok : ValueStreamModel.ValueStream;
    #err : Text;
  } {
    switch (AuthMiddleware.authorize(authContext(caller, ?workspaceId), [#IsWorkspaceAdmin])) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        switch (ValueStreamModel.updateValueStream(workspaceValueStreams, workspaceId, valueStreamId, newName, newProblem, newGoal, newStatus)) {
          case (#err(msg)) { #err(msg) };
          case (#ok(())) {
            ValueStreamModel.getValueStream(workspaceValueStreams, workspaceId, valueStreamId);
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
        switch (ObjectiveModel.updateObjective(workspaceObjectives, workspaceId, valueStreamId, objectiveId, newName, newDescription, newMetricIds, newComputation, newTarget, newTargetDate, newStatus)) {
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
};
