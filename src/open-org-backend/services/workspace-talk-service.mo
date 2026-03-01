import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import AgentRegistryModel "../models/agent-registry-model";
import SecretModel "../models/secret-model";
import KeyDerivationService "./key-derivation-service";
import ConversationModel "../models/conversation-model";
import GroqWrapper "../wrappers/groq-wrapper";

module {

  // Process the workspace talk request after validation.
  //
  // Resolves the agent by ID from the global registry and uses its
  // llmModel and secretsAllowed to authenticate and dispatch the request.
  public func processWorkspaceTalk(
    agentRegistry : AgentRegistryModel.AgentRegistryState,
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
    // Look up the agent by ID in the registry
    let agent = switch (AgentRegistryModel.lookupById(agentId, agentRegistry)) {
      case (null) { return #err("Agent not found.") };
      case (?a) { a };
    };

    // Derive secretId and model string from the agent's llmModel
    let secretId = AgentRegistryModel.llmModelToSecretId(agent.llmModel);
    let modelText = AgentRegistryModel.llmModelToText(agent.llmModel);

    // Guard: ensure this agent is allowed to access the secret for this workspace
    if (not AgentRegistryModel.isSecretAllowed(agent, workspaceId, secretId)) {
      return #err(
        "Agent \"" # agent.name # "\" does not have permission to access the LLM API key for workspace " # Nat.toText(workspaceId) # "."
      );
    };

    // Derive workspace encryption key and decrypt the API key
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let apiKey = SecretModel.getSecret(apiKeys, encryptionKey, workspaceId, secretId);

    // Dispatch to the appropriate provider
    var response : Text = "";
    switch (agent.llmModel) {
      case (#groq(_)) {
        switch (apiKey) {
          case (null) {
            return #err("No Groq API key found for this agent. Please ask a workspace admin to store the API key.");
          };
          case (?key) {
            let groqResult = await GroqWrapper.chat(key, message, modelText);
            switch (groqResult) {
              case (#ok(groqResponse)) { response := groqResponse };
              case (#err(error)) {
                return #err("Groq API Error: " # error);
              };
            };
          };
        };
      };
    };

    // Store the user message and agent response in conversation history
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
