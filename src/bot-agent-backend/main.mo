import Principal "mo:core/Principal";
import Map "mo:core/Map";
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
import Constants "./constants";
import GroqWrapper "./wrappers/groq-wrapper";
// import LLMWrapper "./wrappers/llm-wrapper";

persistent actor {
  // ============================================
  // State
  // ============================================
  var agents = Map.empty<Nat, AgentService.Agent>();
  var nextAgentId : Nat = 0;
  var admins : [Principal] = [];
  var conversations = Map.empty<ConversationService.ConversationKey, List.List<ConversationService.Message>>();
  var apiKeys = Map.empty<Principal, Map.Map<(Nat, Text), ApiKeysService.EncryptedApiKey>>(); // Encrypted API keys
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared

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
  // Admin Management
  // ============================================

  // Add a new admin
  public shared ({ caller }) func addAdmin(newAdmin : Principal) : async {
    #ok : ();
    #err : Text;
  } {
    admins := AdminService.initializeFirstAdmin(caller, admins);

    let validation = AdminService.validateNewAdmin(newAdmin, caller, admins);
    switch (validation) {
      case (#err(msg)) {
        #err(msg);
      };
      case (#ok(())) {
        admins := AdminService.addAdminToList(newAdmin, admins);
        #ok(());
      };
    };
  };

  // Get list of admins
  public query func getAdmins() : async [Principal] {
    admins;
  };

  // Check if caller is admin
  public shared ({ caller }) func isCallerAdmin() : async Bool {
    AdminService.isAdmin(caller, admins);
  };

  // ============================================
  // Agent Management
  // ============================================

  // Create a new agent
  public shared ({ caller }) func createAgent(name : Text, provider : Types.LlmProvider, model : Text) : async {
    #ok : Nat;
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, admins)) {
      return #err("Only admins can create agents");
    };
    let (result, newId) = AgentService.createAgent(name, provider, model, agents, nextAgentId);
    nextAgentId := newId;
    result;
  };

  // Read/Get an agent
  public query func getAgent(id : Nat) : async ?AgentService.Agent {
    AgentService.getAgent(id, agents);
  };

  // Update an agent
  public shared ({ caller }) func updateAgent(id : Nat, newName : ?Text, newProvider : ?Types.LlmProvider, newModel : ?Text) : async {
    #ok : Bool;
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, admins)) {
      return #err("Only admins can update agents");
    };
    AgentService.updateAgent(id, newName, newProvider, newModel, agents);
  };

  // Delete an agent
  public shared ({ caller }) func deleteAgent(id : Nat) : async {
    #ok : Bool;
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, admins)) {
      return #err("Only admins can delete agents");
    };
    AgentService.deleteAgent(id, agents);
  };

  // List all agents
  public query func listAgents() : async [AgentService.Agent] {
    AgentService.listAgents(agents);
  };

  // ============================================
  // Conversation Management
  // ============================================

  // Get conversation history
  public shared ({ caller }) func getConversation(agentId : Nat) : async {
    #ok : [ConversationService.Message];
    #err : Text;
  } {
    ConversationService.getConversation(conversations, caller, agentId);
  };

  public shared ({ caller }) func talkTo(agentId : Nat, message : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      #err("Please login before calling this function");
    } else if (Text.trim(message, #char ' ') == "") {
      #err("Message cannot be empty");
    } else {
      // Get the agent to determine which provider to use
      let agent = AgentService.getAgent(agentId, agents);
      switch (agent) {
        case (null) { return #err("Agent not found") };
        case (?foundAgent) {
          // Get api key (requires deriving encryption key first)
          let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, caller);
          let apiKey = ApiKeysService.getApiKeyForCallerAndAgent(apiKeys, encryptionKey, caller, agentId, foundAgent.provider);

          // Generate response based on provider and API key availability
          var response : Text = "";
          switch (foundAgent.provider) {
            case (#groq) {
              switch (apiKey) {
                case (null) {
                  return #err("No Groq API key found for this agent. Please store your API key first.");
                };
                case (?key) {
                  let groqResult = await GroqWrapper.chat(key, message, foundAgent.model);
                  switch (groqResult) {
                    case (#ok(groqResponse)) { response := groqResponse };
                    case (#err(error)) {
                      return #err("Groq API Error: " # error);
                    };
                  };
                };
              };
            };
            case (#openai) {
              return #err("OpenAI integration not yet implemented.");
            };
            case (#llmcanister) {
              return #err("LLM Canister integration not yet implemented.");
            };
          };

          // Once successful, store the user message and agent response in the conversation history
          ConversationService.addMessageToConversation(
            conversations,
            caller,
            agentId,
            {
              author = #user;
              content = message;
              timestamp = Time.now();
            },
          );

          ConversationService.addMessageToConversation(
            conversations,
            caller,
            agentId,
            {
              author = #agent;
              content = response;
              timestamp = Time.now();
            },
          );

          #ok(response);
        };
      };
    };
  };

  // ============================================
  // API Key Management
  // ============================================

  // Store an API key for an agent (encrypted at rest)
  public shared ({ caller }) func storeApiKey(agentId : Nat, provider : Types.LlmProvider, apiKey : Text) : async {
    #ok : ();
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    } else if (Text.trim(apiKey, #char ' ') == "") {
      return #err("API key cannot be empty");
    } else {
      let agent = AgentService.getAgent(agentId, agents);
      switch (agent) {
        case (null) { return #err("Agent not found") };
        case (?foundAgent) {
          if (foundAgent.provider != provider) {
            return #err("Provider mismatch: Agent uses " # debug_show (foundAgent.provider) # " but you specified " # debug_show (provider) # ".");
          };
        };
      };
    };

    // Derive encryption key for this caller
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, caller);

    ApiKeysService.storeApiKey(apiKeys, encryptionKey, caller, agentId, provider, apiKey);
  };

  // Get caller's own API keys
  public shared ({ caller }) func getMyApiKeys() : async {
    #ok : [(Nat, Text)];
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };
    ApiKeysService.getMyApiKeys(apiKeys, caller);
  };

  // Delete an API key for a specific agent and provider
  public shared ({ caller }) func deleteApiKey(agentId : Nat, provider : Types.LlmProvider) : async {
    #ok : ();
    #err : Text;
  } {
    if (Principal.isAnonymous(caller)) {
      return #err("Please login before calling this function");
    };
    ApiKeysService.deleteApiKey(apiKeys, caller, agentId, provider);
  };

  // ============================================
  // Key Cache Management
  // ============================================

  // Manually clear the key cache (admin only)
  public shared ({ caller }) func clearKeyCache() : async {
    #ok : ();
    #err : Text;
  } {
    if (not AdminService.isAdmin(caller, admins)) {
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
    if (not AdminService.isAdmin(caller, admins)) {
      return #err("Only admins can view cache stats");
    };
    #ok({ size = KeyDerivationService.getCacheSize(keyCache) });
  };
};
