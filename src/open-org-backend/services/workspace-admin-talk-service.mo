import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import ApiKeysModel "../models/api-keys-model";
import KeyDerivationService "./key-derivation-service";
import ConversationModel "../models/conversation-model";
import GroqWrapper "../wrappers/groq-wrapper";
import Constants "../constants";

module {

  // Process the admin talk request after validation
  public func processAdminTalk(
    apiKeys : Map.Map<Nat, Map.Map<Types.LlmProvider, ApiKeysModel.EncryptedApiKey>>,
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceId : Nat,
    message : Text,
    keyCache : KeyDerivationService.KeyCache,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Get api key (requires deriving encryption key for the workspace)
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let apiKey = ApiKeysModel.getApiKey(apiKeys, encryptionKey, workspaceId, Constants.ADMIN_TALK_PROVIDER);

    // Generate response based on provider and API key availability
    var response : Text = "";
    switch (Constants.ADMIN_TALK_PROVIDER) {
      case (#groq) {
        switch (apiKey) {
          case (null) {
            return #err("No Groq API key found for admin talk. Please store the API key first.");
          };
          case (?key) {
            let groqResult = await GroqWrapper.reason(
              key,
              message,
              Constants.ADMIN_TALK_MODEL,
              #workspace(workspaceId),
              null,
              null,
              null,
            );
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

    // Once successful, store the user message and agent response in the admin conversation history
    ConversationModel.addMessageToAdminConversation(
      adminConversations,
      workspaceId,
      {
        author = #user;
        content = message;
        timestamp = Time.now();
      },
    );

    ConversationModel.addMessageToAdminConversation(
      adminConversations,
      workspaceId,
      {
        author = #agent;
        content = response;
        timestamp = Time.now();
      },
    );

    #ok(response);
  };
};
