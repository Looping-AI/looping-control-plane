import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import List "mo:core/List";

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
import EventProcessingContextTypes "../../../src/open-org-backend/events/types/event-processing-context";
import McpToolRegistry "../../../src/open-org-backend/tools/mcp-tool-registry";
import ValueStreamModel "../../../src/open-org-backend/models/value-stream-model";
import ObjectiveModel "../../../src/open-org-backend/models/objective-model";
import MetricModel "../../../src/open-org-backend/models/metric-model";
import ConversationModel "../../../src/open-org-backend/models/conversation-model";
import SecretModel "../../../src/open-org-backend/models/secret-model";
import Types "../../../src/open-org-backend/types";

// ============================================
// Test Canister
// ============================================

// IMPORTANT:
// Never add this canister to dfx or deploy it

shared ({ caller = parent }) persistent actor class TestCanister() {
  // Store for HTTP certification testing
  var certStore = HttpCertification.initStore();

  // ============================================
  // Test Helpers
  // ============================================

  /// Creates an empty EventProcessingContext suitable for unit tests.
  /// All state is empty/default; secrets and conversations are not pre-populated,
  /// so handlers that require them (e.g. MessageHandler) will return graceful
  /// error steps rather than crashing.
  ///
  /// keyCache is pre-seeded with a dummy 32-byte key for common test workspace IDs
  /// (0, 1, 42) to avoid live Schnorr threshold-key calls during unit tests.
  private func emptyCtx() : EventProcessingContextTypes.EventProcessingContext {
    // A deterministic dummy 32-byte key used for all workspaces in unit tests.
    // Secrets aren't populated so the encryption key is never actually used for
    // decryption — it just needs to exist so getOrDeriveKey returns immediately.
    let dummyKey : [Nat8] = [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ];
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, dummyKey), (1, dummyKey), (42, dummyKey)],
      Nat.compare,
    );
    {
      secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
      keyCache;
      adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();
      mcpToolRegistry = McpToolRegistry.empty();
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
    };
  };

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
    await MessageHandler.handle(workspaceId, msg, emptyCtx());
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
    await BotMessageHandler.handle(workspaceId, bot, emptyCtx());
  };

  public shared ({ caller }) func testMessageDeletedHandler(
    workspaceId : Nat,
    deleted : {
      channel : Text;
      deletedTs : Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageDeletedHandler.handle(workspaceId, deleted, emptyCtx());
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
    await MessageEditedHandler.handle(workspaceId, edited, emptyCtx());
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
    await ThreadEventHandler.handle(workspaceId, thread, emptyCtx());
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
