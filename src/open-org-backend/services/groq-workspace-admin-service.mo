import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Map "mo:core/Map";
import ConversationModel "../models/conversation-model";
import GroqWrapper "../wrappers/groq-wrapper";
import Constants "../constants";
import InstructionComposer "../instructions/instruction-composer";

module {

  // Execute admin talk using Groq LLM
  public func executeAdminTalk(
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceId : Nat,
    message : Text,
    apiKey : Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Compose instructions for workspace admin context
    let instructions = InstructionComposer.compose(
      #workspaceAdmin,
      [], // No additional context flags for now
      [], // No custom blocks
    );

    let groqResult = await GroqWrapper.reason(
      apiKey,
      message,
      Constants.ADMIN_TALK_MODEL,
      #workspace(workspaceId),
      ?instructions,
      null,
      null,
    );

    let response = switch (groqResult) {
      case (#ok(groqResponse)) { groqResponse };
      case (#err(error)) {
        return #err("Groq API Error: " # error);
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
