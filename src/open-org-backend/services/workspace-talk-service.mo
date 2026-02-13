import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import AgentModel "../models/agent-model";
import SecretModel "../models/secret-model";
import KeyDerivationService "./key-derivation-service";
import ConversationModel "../models/conversation-model";
import GroqWrapper "../wrappers/groq-wrapper";

module {

  // Get agent for a given workspace
  private func getAgentForWorkspace(
    workspaceAgents : Map.Map<Nat, AgentModel.WorkspaceAgentsState>,
    workspaceId : Nat,
    agentId : Nat,
  ) : ?AgentModel.Agent {
    switch (Map.get(workspaceAgents, Nat.compare, workspaceId)) {
      case (null) { null };
      case (?workspaceState) {
        AgentModel.getAgent(agentId, workspaceState);
      };
    };
  };

  // Process the workspace talk request after validation
  public func processWorkspaceTalk(
    workspaceAgents : Map.Map<Nat, AgentModel.WorkspaceAgentsState>,
    apiKeys : Map.Map<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>,
    conversations : Map.Map<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>,
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
        #err("Agent not found.");
      };
      case (?foundAgent) {
        // Get api key (requires deriving encryption key for the workspace)
        let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
        let secretId : Types.SecretId = switch (foundAgent.provider) {
          case (#groq) { #groqApiKey };
          case (#openai) { #openaiApiKey };
        };
        let apiKey = SecretModel.getSecret(apiKeys, encryptionKey, workspaceId, secretId);

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
        };

        // Once successful, store the user message and agent response in the conversation history
        ConversationModel.addMessageToConversation(
          conversations,
          workspaceId,
          agentId,
          {
            author = #user;
            content = message;
            timestamp = Time.now();
          },
        );

        ConversationModel.addMessageToConversation(
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
