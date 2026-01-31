import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import ConversationModel "../../../../src/open-org-backend/models/conversation-model";

// Helper functions for Result comparison
func resultMessagesToText(r : Result.Result<[ConversationModel.Message], Text>) : Text {
  switch (r) {
    case (#ok msgs) { "#ok([" # Nat.toText(msgs.size()) # " messages])" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultMessagesEqual(
  r1 : Result.Result<[ConversationModel.Message], Text>,
  r2 : Result.Result<[ConversationModel.Message], Text>,
) : Bool {
  switch (r1, r2) {
    case (#ok(m1), #ok(m2)) { m1.size() == m2.size() };
    case (#err(e1), #err(e2)) { e1 == e2 };
    case (_, _) { false };
  };
};

// Test data
let testTimestamp : Int = 1_000_000_000_000_000_000;

func createTestMessage(content : Text, isUser : Bool) : ConversationModel.Message {
  {
    author = if (isUser) { #user } else { #agent };
    content;
    timestamp = testTimestamp;
  };
};

suite(
  "ConversationModel - conversationKeyCompare",
  func() {
    test(
      "equal keys return #equal",
      func() {
        let key1 : ConversationModel.ConversationKey = (1, 2);
        let key2 : ConversationModel.ConversationKey = (1, 2);
        let result = ConversationModel.conversationKeyCompare(key1, key2);
        expect.bool(result == #equal).equal(true);
      },
    );

    test(
      "different workspaceId returns correct order",
      func() {
        let key1 : ConversationModel.ConversationKey = (1, 5);
        let key2 : ConversationModel.ConversationKey = (2, 5);
        let result = ConversationModel.conversationKeyCompare(key1, key2);
        expect.bool(result == #less).equal(true);

        let result2 = ConversationModel.conversationKeyCompare(key2, key1);
        expect.bool(result2 == #greater).equal(true);
      },
    );

    test(
      "same workspaceId, different agentId returns correct order",
      func() {
        let key1 : ConversationModel.ConversationKey = (1, 2);
        let key2 : ConversationModel.ConversationKey = (1, 5);
        let result = ConversationModel.conversationKeyCompare(key1, key2);
        expect.bool(result == #less).equal(true);

        let result2 = ConversationModel.conversationKeyCompare(key2, key1);
        expect.bool(result2 == #greater).equal(true);
      },
    );
  },
);

suite(
  "ConversationModel - addMessageToConversation",
  func() {
    test(
      "creates new conversation when none exists",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();
        let message = createTestMessage("Hello", true);

        ConversationModel.addMessageToConversation(conversations, 0, 1, message);

        let result = ConversationModel.getConversation(conversations, 0, 1);
        switch (result) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(1);
            expect.text(msgs[0].content).equal("Hello");
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "appends to existing conversation",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("First", true));
        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("Second", false));
        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("Third", true));

        let result = ConversationModel.getConversation(conversations, 0, 1);
        switch (result) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(3);
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "maintains separate conversations per agent",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("To Agent 1", true));
        ConversationModel.addMessageToConversation(conversations, 0, 2, createTestMessage("To Agent 2", true));
        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("Another to Agent 1", true));

        let result1 = ConversationModel.getConversation(conversations, 0, 1);
        let result2 = ConversationModel.getConversation(conversations, 0, 2);

        switch (result1) {
          case (#ok(msgs)) { expect.nat(msgs.size()).equal(2) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };

        switch (result2) {
          case (#ok(msgs)) { expect.nat(msgs.size()).equal(1) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "maintains separate conversations per workspace",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("Workspace 0", true));
        ConversationModel.addMessageToConversation(conversations, 1, 1, createTestMessage("Workspace 1", true));

        let result0 = ConversationModel.getConversation(conversations, 0, 1);
        let result1 = ConversationModel.getConversation(conversations, 1, 1);

        switch (result0) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(1);
            expect.text(msgs[0].content).equal("Workspace 0");
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };

        switch (result1) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(1);
            expect.text(msgs[0].content).equal("Workspace 1");
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "ConversationModel - getConversation",
  func() {
    test(
      "returns error for non-existent conversation",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();
        let result = ConversationModel.getConversation(conversations, 0, 999);

        expect.result<[ConversationModel.Message], Text>(
          result,
          resultMessagesToText,
          resultMessagesEqual,
        ).isErr();
      },
    );

    test(
      "returns messages in order",
      func() {
        let conversations = Map.empty<ConversationModel.ConversationKey, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("First", true));
        ConversationModel.addMessageToConversation(conversations, 0, 1, createTestMessage("Second", false));

        let result = ConversationModel.getConversation(conversations, 0, 1);
        switch (result) {
          case (#ok(msgs)) {
            expect.text(msgs[0].content).equal("First");
            expect.text(msgs[1].content).equal("Second");
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );
  },
);

suite(
  "ConversationModel - Admin Conversations",
  func() {
    test(
      "addMessageToAdminConversation creates new conversation",
      func() {
        let adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();
        let message = createTestMessage("Admin message", true);

        ConversationModel.addMessageToAdminConversation(adminConversations, 0, message);

        let result = ConversationModel.getAdminConversation(adminConversations, 0);
        switch (result) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(1);
            expect.text(msgs[0].content).equal("Admin message");
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "addMessageToAdminConversation appends to existing",
      func() {
        let adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToAdminConversation(adminConversations, 0, createTestMessage("First", true));
        ConversationModel.addMessageToAdminConversation(adminConversations, 0, createTestMessage("Second", false));

        let result = ConversationModel.getAdminConversation(adminConversations, 0);
        switch (result) {
          case (#ok(msgs)) {
            expect.nat(msgs.size()).equal(2);
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "maintains separate admin conversations per workspace",
      func() {
        let adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();

        ConversationModel.addMessageToAdminConversation(adminConversations, 0, createTestMessage("WS 0", true));
        ConversationModel.addMessageToAdminConversation(adminConversations, 1, createTestMessage("WS 1", true));
        ConversationModel.addMessageToAdminConversation(adminConversations, 0, createTestMessage("WS 0 again", true));

        let result0 = ConversationModel.getAdminConversation(adminConversations, 0);
        let result1 = ConversationModel.getAdminConversation(adminConversations, 1);

        switch (result0) {
          case (#ok(msgs)) { expect.nat(msgs.size()).equal(2) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };

        switch (result1) {
          case (#ok(msgs)) { expect.nat(msgs.size()).equal(1) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "getAdminConversation returns error for non-existent workspace",
      func() {
        let adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();
        let result = ConversationModel.getAdminConversation(adminConversations, 999);

        expect.result<[ConversationModel.Message], Text>(
          result,
          resultMessagesToText,
          resultMessagesEqual,
        ).isErr();
      },
    );
  },
);
