import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import List "mo:core/List";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Int "mo:core/Int";
import Types "./types";
import AdminService "./services/admin-service";
import AgentService "./services/agent-service";
import ConversationService "./services/conversation-service";
import ApiKeysService "./services/api-keys-service";
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
  var conversations = Map.empty<ConversationService.ConversationKey, List.List<ConversationService.Message>>();
  var apiKeys = Map.empty<Nat, Map.Map<(Nat, Text), ApiKeysService.EncryptedApiKey>>(); // Encrypted API keys per workspace
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys per workspace
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared
  var workspaceAdmins = Map.fromArray<Nat, [Principal]>([(0, [owner])], Nat.compare); // Workspace exists only if ID is present here
  var workspaceMembers = Map.fromArray<Nat, [Principal]>([(0, [])], Nat.compare); // Members of each workspace
  var nextAgentId : Nat = 0;
  var workspaceAgents = Map.fromArray<Nat, Map.Map<Nat, AgentService.Agent>>([(0, Map.empty<Nat, AgentService.Agent>())], Nat.compare);

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
    let validation = AdminService.validateNewAdminAsOwner(newAdmin, caller, orgOwner, orgAdmins);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        orgAdmins := AdminService.addAdminToList(newAdmin, orgAdmins);
        #ok(());
      };
    };
  };

  // Get list of organization admins
  public query func getOrgAdmins() : async [Principal] {
    orgAdmins;
  };

  // Check if caller is an organization admin
  public shared ({ caller }) func isCallerOrgAdmin() : async Bool {
    AdminService.isAdmin(caller, orgAdmins);
  };

  // Add a new workspace admin
  public shared ({ caller }) func addWorkspaceAdmin(workspaceId : Nat, newAdmin : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    let validation = AdminService.validateNewWorkspaceAdmin(newAdmin, caller, orgOwner, workspaceId, workspaceAdmins);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        switch (Map.get(workspaceAdmins, Nat.compare, workspaceId)) {
          case (?admins) {
            let newAdmins = AdminService.addAdminToList(newAdmin, admins);
            Map.add(workspaceAdmins, Nat.compare, workspaceId, newAdmins);
            #ok(());
          };
          case (null) {
            // This should never happen since validation already checked
            #err("Workspace not found");
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
    let validation = AdminService.validateNewWorkspaceMember(newMember, caller, orgOwner, workspaceId, workspaceAdmins, workspaceMembers);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
          case (?members) {
            let newMembers = AdminService.addMemberToList(newMember, members);
            Map.add(workspaceMembers, Nat.compare, workspaceId, newMembers);
            #ok(());
          };
          case (null) {
            // This should never happen since validation already checked
            #err("Workspace not found");
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
    let validation = AdminService.validateCanViewWorkspaceMembers(caller, workspaceId, workspaceAdmins);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
          case (null) {
            #err("Workspace not found");
          };
          case (?members) {
            #ok(members);
          };
        };
      };
    };
  };

  // Check if caller is a workspace member
  public shared ({ caller }) func isCallerWorkspaceMember(workspaceId : Nat) : async Bool {
    AdminService.isWorkspaceMember(caller, workspaceId, workspaceMembers);
  };

  // ============================================
  // Agent Management
  // ============================================

  // Create a new agent
  public shared ({ caller }) func createAgent(workspaceId : Nat, name : Text, provider : Types.LlmProvider, model : Text) : async {
    #ok : Nat;
    #err : Text;
  } {
    // Check if caller is admin in this workspace
    if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can create agents");
    };
    switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
      case (null) {
        #err("Workspace not found");
      };
      case (?agents) {
        let (result, newId) = AgentService.createAgent(name, provider, model, agents, nextAgentId);
        nextAgentId := newId;
        result;
      };
    };
  };

  // Read/Get an agent
  public shared ({ caller }) func getAgent(workspaceId : Nat, id : Nat) : async {
    #ok : ?AgentService.Agent;
    #err : Text;
  } {
    // Validate if caller has access to this workspace
    let accessValidation = AdminService.validateWorkspaceAccess(caller, workspaceId, workspaceAdmins, workspaceMembers);
    switch (accessValidation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found") };
          case (?agents) {
            #ok(AgentService.getAgent(id, agents));
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
    // Check if caller is admin in this workspace
    if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can update agents");
    };
    switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
      case (null) {
        #err("Workspace not found");
      };
      case (?agents) {
        AgentService.updateAgent(id, newName, newProvider, newModel, agents);
      };
    };
  };

  // Delete an agent
  public shared ({ caller }) func deleteAgent(workspaceId : Nat, id : Nat) : async {
    #ok : Bool;
    #err : Text;
  } {
    // Check if caller is admin in this workspace
    if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can delete agents");
    };
    switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
      case (null) {
        #err("Workspace not found");
      };
      case (?agents) {
        AgentService.deleteAgent(id, agents);
      };
    };
  };

  // List all agents
  public shared ({ caller }) func listAgents(workspaceId : Nat) : async {
    #ok : [AgentService.Agent];
    #err : Text;
  } {
    // Validate if caller has access to this workspace
    let accessValidation = AdminService.validateWorkspaceAccess(caller, workspaceId, workspaceAdmins, workspaceMembers);
    switch (accessValidation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
          case (null) { #err("Workspace not found") };
          case (?agents) {
            #ok(AgentService.listAgents(agents));
          };
        };
      };
    };
  };

  // ============================================
  // Conversation Management
  // ============================================

  // Get conversation history
  public shared ({ caller }) func getConversation(workspaceId : Nat, agentId : Nat) : async {
    #ok : [ConversationService.Message];
    #err : Text;
  } {
    // Validate if caller has access to this workspace
    let accessValidation = AdminService.validateWorkspaceAccess(caller, workspaceId, workspaceAdmins, workspaceMembers);
    switch (accessValidation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        ConversationService.getConversation(conversations, workspaceId, agentId);
      };
    };
  };

  // ============================================
  // Workspace Admin Talk
  // ============================================

  public shared ({ caller }) func workspaceAdminTalk(workspaceId : Nat, agentId : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else if (Text.trim(message, #char ' ') == "") {
      #err("Message cannot be empty");
    } else if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      #err("Only workspace admins can use this function");
    } else {
      // Delegate to service for business logic
      return await WorkspaceAdminTalkService.processAdminTalk(
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

  // ============================================
  // Workspace Talk
  // ============================================

  public shared ({ caller }) func workspaceTalk(workspaceId : Nat, agentId : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else if (Text.trim(message, #char ' ') == "") {
      #err("Message cannot be empty");
    } else {
      // Validate if caller has access to this workspace
      let accessValidation = AdminService.validateWorkspaceAccess(caller, workspaceId, workspaceAdmins, workspaceMembers);
      switch (accessValidation) {
        case (#err(msg)) {
          return #err(msg);
        };
        case (#ok(())) {
          // Delegate to service for business logic
          return await WorkspaceTalkService.processWorkspaceTalk(
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
  };

  // ============================================
  // API Key Management
  // ============================================

  // Store an API key for an agent (encrypted at rest)
  // Only workspace admins can store API keys
  public shared ({ caller }) func storeApiKey(workspaceId : Nat, agentId : Nat, provider : Types.LlmProvider, apiKey : Text) : async {
    #ok : ();
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    } else if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can store API keys");
    } else if (Text.trim(apiKey, #char ' ') == "") {
      return #err("API key cannot be empty");
    } else {
      let agent = switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
        case (null) {
          return #err("Workspace not found");
        };
        case (?agents) {
          AgentService.getAgent(agentId, agents);
        };
      };
      switch (agent) {
        case (null) { return #err("Agent not found") };
        case (?foundAgent) {
          if (foundAgent.provider != provider) {
            return #err("Provider mismatch: Agent uses " # debug_show (foundAgent.provider) # " but you specified " # debug_show (provider) # ".");
          };
        };
      };
    };

    // Derive encryption key for this workspace
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);

    ApiKeysService.storeApiKey(apiKeys, encryptionKey, workspaceId, agentId, provider, apiKey);
  };

  // Get API keys for a workspace
  // Only workspace admins can view API keys
  public shared ({ caller }) func getWorkspaceApiKeys(workspaceId : Nat) : async {
    #ok : [(Nat, Text)];
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };
    if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can view which API keys exist");
    };
    ApiKeysService.getWorkspaceApiKeys(apiKeys, workspaceId);
  };

  // Delete an API key for a specific agent and provider in a workspace
  // Only workspace admins can delete API keys
  public shared ({ caller }) func deleteApiKey(workspaceId : Nat, agentId : Nat, provider : Types.LlmProvider) : async {
    #ok : ();
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };
    if (not AdminService.isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only workspace admins can delete API keys");
    };
    ApiKeysService.deleteApiKey(apiKeys, workspaceId, agentId, provider);
  };

  // ============================================
  // Key Cache Management
  // ============================================

  // Manually clear the key cache (admin only)
  public shared ({ caller }) func clearKeyCache() : async {
    #ok : ();
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, orgAdmins)) {
      return #err("Only admins can clear the key cache");
    };
    keyCache := KeyDerivationService.clearCache();
    #ok(());
  };

  // Get cache statistics (admin only)
  public shared ({ caller }) func getKeyCacheStats() : async {
    #ok : { size : Nat };
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, orgAdmins)) {
      return #err("Only admins can view cache stats");
    };
    #ok({ size = KeyDerivationService.getCacheSize(keyCache) });
  };
};
