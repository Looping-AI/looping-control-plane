import Error "mo:core/Error";

import HttpWrapper "../../../src/open-org-backend/wrappers/http-wrapper";
import GroqWrapper "../../../src/open-org-backend/wrappers/groq-wrapper";
import HttpCertification "../../../src/open-org-backend/utilities/http-certification";
import MessageHandler "../../../src/open-org-backend/events/handlers/message-handler";
import BotMessageHandler "../../../src/open-org-backend/events/handlers/bot-message-handler";
import MessageDeletedHandler "../../../src/open-org-backend/events/handlers/message-deleted-handler";
import MessageEditedHandler "../../../src/open-org-backend/events/handlers/message-edited-handler";
import ThreadEventHandler "../../../src/open-org-backend/events/handlers/thread-event-handler";
import NormalizedEventTypes "../../../src/open-org-backend/events/types/normalized-event-types";
import SlackAdapter "../../../src/open-org-backend/events/slack-adapter";

// ============================================
// Test Canister
// ============================================

// IMPORTANT:
// Never add this canister to dfx or deploy it

shared ({ caller = parent }) persistent actor class TestCanister() {
  // Store for HTTP certification testing
  var certStore = HttpCertification.initStore();

  public shared ({ caller }) func httpGet(url : Text, headers : [HttpWrapper.HttpHeader]) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.get(url, headers);
  };

  public shared ({ caller }) func httpPost(url : Text, headers : [HttpWrapper.HttpHeader], body : Text) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.post(url, headers, body);
  };

  public shared ({ caller }) func groqChat(apiKey : Text, userMessage : Text, model : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.chat(apiKey, userMessage, model);
  };

  public shared ({ caller }) func groqReason(
    apiKey : Text,
    input : [GroqWrapper.ResponseInputMessage],
    model : Text,
    trackId : GroqWrapper.TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[GroqWrapper.Tool],
  ) : async GroqWrapper.ReasonWithToolsResult {
    assert caller == parent;
    await GroqWrapper.reason(apiKey, input, model, trackId, instructions, temperature, tools);
  };

  public shared ({ caller }) func groqUseBuiltInTool(
    apiKey : Text,
    userMessage : Text,
    tool : GroqWrapper.BuiltInTool,
  ) : async {
    #ok : GroqWrapper.CompoundChatCompletionResponse;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.useBuiltInTool(apiKey, userMessage, tool);
  };

  // ============================================
  // HTTP Certification Methods
  // ============================================

  public shared ({ caller }) func httpCertInit() : async () {
    assert caller == parent;
    certStore := HttpCertification.initStore();
  };

  public shared ({ caller }) func httpCertCertifyPath(url : Text) : async () {
    assert caller == parent;
    HttpCertification.certifySkipFallbackPath(certStore, url);
  };

  public query func httpCertGetHeaders(url : Text) : async {
    #ok : [(Text, Text)];
    #err : Text;
  } {
    try {
      let headers = HttpCertification.getSkipCertificationHeaders(certStore, url);
      #ok(headers);
    } catch (_) {
      #err("Failed to get headers");
    };
  };

  /// Check if a path exists in the MerkleTree and return its details
  public query func httpCertCheckPath(url : Text) : async {
    #ok : {
      exists : Bool;
      path : [Text];
      treeHash : Blob;
    };
    #err : Text;
  } {
    try {
      let result = HttpCertification.checkPath(certStore, url);
      #ok(result);
    } catch (e) {
      #err("Failed to check path: " # Error.message(e));
    };
  };

  // ============================================
  // Handler Test Methods
  // ============================================

  public shared ({ caller }) func testMessageHandler(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(workspaceId, msg);
  };

  public shared ({ caller }) func testBotMessageHandler(
    workspaceId : Nat,
    bot : {
      botId : Text;
      text : Text;
      channel : Text;
      ts : Text;
      username : ?Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await BotMessageHandler.handle(workspaceId, bot);
  };

  public shared ({ caller }) func testMessageDeletedHandler(
    workspaceId : Nat,
    deleted : {
      channel : Text;
      deletedTs : Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageDeletedHandler.handle(workspaceId, deleted);
  };

  public shared ({ caller }) func testMessageEditedHandler(
    workspaceId : Nat,
    edited : {
      channel : Text;
      messageTs : Text;
      newText : Text;
      editedBy : ?Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageEditedHandler.handle(workspaceId, edited);
  };

  public shared ({ caller }) func testThreadEventHandler(
    workspaceId : Nat,
    thread : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await ThreadEventHandler.handle(workspaceId, thread);
  };

  // ============================================
  // Slack Adapter Test Methods
  // ============================================

  public query func testSlackSignatureVerification(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : async Bool {
    SlackAdapter.verifySignature(signingSecret, signature, timestamp, body);
  };

  public query func testSlackTimestampVerification(timestamp : Text) : async Bool {
    SlackAdapter.verifyTimestamp(timestamp);
  };
};
