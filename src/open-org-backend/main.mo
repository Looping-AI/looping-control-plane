import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Int "mo:core/Int";
import Types "./types";
import AuthMiddleware "./middleware/auth-middleware";
import AdminModel "./models/admin-model";
import AgentModel "./models/agent-model";
import ConversationModel "./models/conversation-model";
import ApiKeysModel "./models/api-keys-model";
import KeyDerivationService "./services/key-derivation-service";
import WorkspaceTalkService "./services/workspace-talk-service";
import WorkspaceAdminTalkService "./services/workspace-admin-talk-service";
import Constants "./constants";

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
  var workspaceAdmins = Map.fromArray<Nat, [Principal]>([(0, [owner])], Nat.compare); // Workspace exists only if ID is present here
  var workspaceMembers = Map.fromArray<Nat, [Principal]>([(0, [])], Nat.compare); // Members of each workspace
  var nextAgentId : Nat = 0;
  var workspaceAgents = Map.fromArray<Nat, Map.Map<Nat, AgentModel.Agent>>([(0, Map.empty<Nat, AgentModel.Agent>())], Nat.compare);

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

  // This logic runs only on the VERY FIRST installation (init)
  // Subsequent upgrades will wipe this timer and it won't be replaced
  let _initTimer = Timer.setTimer<system>(
    #nanoseconds(Constants.THIRTY_DAYS_NS),
    clearKeyCacheTimer,
  );

  // System hook called after every upgrade
  system func postupgrade() {
    let now = Time.now();
    let elapsed = now - lastClearTimestamp;

    let remaining = Constants.THIRTY_DAYS_NS - elapsed;
    ignore Timer.setTimer<system>(#nanoseconds(Int.abs(remaining)), clearKeyCacheTimer);
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
        // Delegate to service for business logic
        await WorkspaceAdminTalkService.processAdminTalk(
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
};
