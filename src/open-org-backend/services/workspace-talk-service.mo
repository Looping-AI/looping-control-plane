import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import AgentService "./agent-service";
import ApiKeysService "./api-keys-service";
import KeyDerivationService "./key-derivation-service";
import ConversationService "./conversation-service";
import GroqWrapper "../wrappers/groq-wrapper";
// import LLMWrapper "./wrappers/llm-wrapper";

module {

  // Get agent for a given workspace
  private func getAgentForWorkspace(
    workspaceAgents : Map.Map<Nat, Map.Map<Nat, AgentService.Agent>>,
    workspaceId : Nat,
    agentId : Nat,
  ) : ?AgentService.Agent {
    switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
      case (null) { null };
      case (?agents) {
        AgentService.getAgent(agentId, agents);
      };
    };
  };

  // Process the workspace talk request after validation
  public func processWorkspaceTalk(
    workspaceAgents : Map.Map<Nat, Map.Map<Nat, AgentService.Agent>>,
    apiKeys : Map.Map<Nat, Map.Map<(Nat, Text), ApiKeysService.EncryptedApiKey>>,
    conversations : Map.Map<ConversationService.ConversationKey, List.List<ConversationService.Message>>,
    workspaceId : Nat,
    agentId : Nat,
    message : Text,
    keyCache : KeyDerivationService.KeyCache,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    let agent = getAgentForWorkspace(workspaceAgents, workspaceId, agentId);
    switch (agent) {
      case (null) {
        #err("Agent not found");
      };
      case (?foundAgent) {
        // Get api key (requires deriving encryption key for the workspace)
        let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
        let apiKey = ApiKeysService.getApiKeyForWorkspaceAndAgent(apiKeys, encryptionKey, workspaceId, agentId, foundAgent.provider);

        // Generate response based on provider and API key availability
        var response : Text = "";
        switch (foundAgent.provider) {
          case (#groq) {
            switch (apiKey) {
              case (null) {
                return #err("No Groq API key found for this agent. Please ask a workspace admin to store the API key.");
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
          workspaceId,
          agentId,
          {
            author = #user;
            content = message;
            timestamp = Time.now();
          },
        );

        ConversationService.addMessageToConversation(
          conversations,
          workspaceId,
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
