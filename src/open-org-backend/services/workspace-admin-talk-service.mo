import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import AgentService "./agent-service";
import ApiKeysService "./api-keys-service";
import KeyDerivationService "./key-derivation-service";
import ConversationService "./conversation-service";
import GroqWrapper "../wrappers/groq-wrapper";
import Constants "../constants";

module {

  // Process the admin talk request after validation
  public func processAdminTalk(
    apiKeys : Map.Map<Nat, Map.Map<Types.LlmProvider, ApiKeysService.EncryptedApiKey>>,
    conversations : Map.Map<ConversationService.ConversationKey, List.List<ConversationService.Message>>,
    workspaceId : Nat,
    message : Text,
    keyCache : KeyDerivationService.KeyCache,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Get api key (requires deriving encryption key for the workspace)
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let apiKey = ApiKeysService.getApiKey(apiKeys, encryptionKey, workspaceId, Constants.ADMIN_TALK_PROVIDER);

    // Generate response based on provider and API key availability
    var response : Text = "";
    switch (Constants.ADMIN_TALK_PROVIDER) {
      case (#groq) {
        switch (apiKey) {
          case (null) {
            return #err("No Groq API key found for admin talk. Please store the API key first.");
          };
          case (?key) {
            let groqResult = await GroqWrapper.chat(key, message, Constants.ADMIN_TALK_MODEL);
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
    // Note: Using Nat 0 as a fixed admin talk agent id
    ConversationService.addMessageToConversation(
      conversations,
      workspaceId,
      0,
      {
        author = #user;
        content = message;
        timestamp = Time.now();
      },
    );

    ConversationService.addMessageToConversation(
      conversations,
      workspaceId,
      0,
      {
        author = #agent;
        content = response;
        timestamp = Time.now();
      },
    );

    #ok(response);
  };
};
