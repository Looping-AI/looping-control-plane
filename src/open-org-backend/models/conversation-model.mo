import Map "mo:core/Map";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Result "mo:core/Result";

module {
  public type Message = {
    author : {
      #user;
      #agent;
      #tool_call;
      #tool_response;
    };
    content : Text;
    timestamp : Int;
  };

  public type ConversationKey = (Nat, Nat); // (workspaceId, agentId)

  // Comparison function for ConversationKey
  public func conversationKeyCompare(a : ConversationKey, b : ConversationKey) : {
    #less;
    #equal;
    #greater;
  } {
    switch (Nat.compare(a.0, b.0)) {
      case (#equal) {
        Nat.compare(a.1, b.1);
      };
      case (other) {
        other;
      };
    };
  };

  // Add a message to a conversation
  public func addMessageToConversation(
    conversations : Map.Map<ConversationKey, List.List<Message>>,
    workspaceId : Nat,
    agentId : Nat,
    message : Message,
  ) {
    let key = (workspaceId, agentId);
    switch (Map.get(conversations, conversationKeyCompare, key)) {
      case (null) {
        let newList = List.empty<Message>();
        List.add(newList, message);
        Map.add(conversations, conversationKeyCompare, key, newList);
      };
      case (?existingList) {
        List.add(existingList, message);
      };
    };
  };

  // Get conversation history
  public func getConversation(
    conversations : Map.Map<ConversationKey, List.List<Message>>,
    workspaceId : Nat,
    agentId : Nat,
  ) : Result.Result<[Message], Text> {
    let key = (workspaceId, agentId);
    switch (Map.get(conversations, conversationKeyCompare, key)) {
      case (null) {
        #err("No conversation found with agent " # debug_show (agentId) # ".");
      };
      case (?messages) {
        #ok(List.toArray(messages));
      };
    };
  };

  // Add message to a workspace admin conversation
  public func addMessageToAdminConversation(
    adminConversations : Map.Map<Nat, List.List<Message>>,
    workspaceId : Nat,
    message : Message,
  ) {
    switch (Map.get(adminConversations, Nat.compare, workspaceId)) {
      case (null) {
        let newList = List.empty<Message>();
        List.add(newList, message);
        Map.add(adminConversations, Nat.compare, workspaceId, newList);
      };
      case (?existingList) {
        List.add(existingList, message);
      };
    };
  };

  // Get admin conversation history (workspace-level, no agent)
  public func getAdminConversation(
    adminConversations : Map.Map<Nat, List.List<Message>>,
    workspaceId : Nat,
  ) : Result.Result<[Message], Text> {
    switch (Map.get(adminConversations, Nat.compare, workspaceId)) {
      case (null) {
        #err("No admin conversation found for workspace " # debug_show (workspaceId) # ".");
      };
      case (?messages) {
        #ok(List.toArray(messages));
      };
    };
  };
};
