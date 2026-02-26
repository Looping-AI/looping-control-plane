import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import List "mo:core/List";

import HttpWrapper "../../../src/open-org-backend/wrappers/http-wrapper";
import GroqWrapper "../../../src/open-org-backend/wrappers/groq-wrapper";
import SlackWrapper "../../../src/open-org-backend/wrappers/slack-wrapper";
import HttpCertification "../../../src/open-org-backend/utilities/http-certification";
import MessageHandler "../../../src/open-org-backend/events/handlers/message-handler";
import MessageDeletedHandler "../../../src/open-org-backend/events/handlers/message-deleted-handler";
import MessageEditedHandler "../../../src/open-org-backend/events/handlers/message-edited-handler";
import AssistantThreadHandler "../../../src/open-org-backend/events/handlers/assistant-thread-handler";
import NormalizedEventTypes "../../../src/open-org-backend/events/types/normalized-event-types";
import SlackAdapter "../../../src/open-org-backend/events/slack-adapter";
import EventProcessingContextTypes "../../../src/open-org-backend/events/types/event-processing-context";
import McpToolRegistry "../../../src/open-org-backend/tools/mcp-tool-registry";
import ValueStreamModel "../../../src/open-org-backend/models/value-stream-model";
import ObjectiveModel "../../../src/open-org-backend/models/objective-model";
import MetricModel "../../../src/open-org-backend/models/metric-model";
import ConversationModel "../../../src/open-org-backend/models/conversation-model";
import SecretModel "../../../src/open-org-backend/models/secret-model";
import SlackUserModel "../../../src/open-org-backend/models/slack-user-model";
import WorkspaceModel "../../../src/open-org-backend/models/workspace-model";
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

  /// The deterministic 32-byte all-zeros key used for every workspace in unit tests.
  /// Seeding keyCache with this key avoids live Schnorr threshold-key calls.
  private let testDummyKey : [Nat8] = [
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

  /// Creates an empty EventProcessingContext suitable for unit tests.
  /// Secrets are not populated so handlers that require them will return graceful
  /// error steps rather than crashing.
  private func emptyCtx() : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
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
      slackUsers = SlackUserModel.empty();
      workspaces = WorkspaceModel.emptyState();
    };
  };

  /// Creates an EventProcessingContext pre-seeded with a Slack bot token and a Groq
  /// API key, both encrypted with the deterministic dummy key used across unit tests.
  /// This lets message-handler tests reach the Slack-posting code path without live
  /// Schnorr key derivation or a real secret-store call.
  ///
  /// Secrets are stored for workspace IDs 0, 1, and 42.
  private func ctxWithSecrets(botToken : Text, groqApiKey : Text) : EventProcessingContextTypes.EventProcessingContext {
    let keyCache = Map.fromArray<Nat, [Nat8]>(
      [(0, testDummyKey), (1, testDummyKey), (42, testDummyKey)],
      Nat.compare,
    );
    let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>();
    for (wsId in [0, 1, 42].vals()) {
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #slackBotToken, botToken);
      ignore SecretModel.storeSecret(secrets, testDummyKey, wsId, #groqApiKey, groqApiKey);
    };
    {
      secrets;
      keyCache;
      adminConversations = Map.empty<Nat, List.List<ConversationModel.Message>>();
      mcpToolRegistry = McpToolRegistry.empty();
      workspaceValueStreams = Map.empty<Nat, ValueStreamModel.WorkspaceValueStreamsState>();
      workspaceObjectives = Map.empty<Nat, ObjectiveModel.WorkspaceObjectivesMap>();
      metricsRegistry = MetricModel.emptyRegistry();
      metricDatapoints = MetricModel.emptyDatapoints();
      slackUsers = SlackUserModel.empty();
      workspaces = WorkspaceModel.emptyState();
    };
  };

  // ============================================
  // Slack Wrapper Test Methods
  // ============================================

  public shared ({ caller }) func slackGetOrganizationMembers(token : Text) : async {
    #ok : [SlackWrapper.SlackUser];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getOrganizationMembers(token);
  };

  public shared ({ caller }) func slackListChannels(token : Text, types : ?Text) : async {
    #ok : [SlackWrapper.SlackChannel];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.listChannels(token, types);
  };

  public shared ({ caller }) func slackGetChannelMembers(token : Text, channel : Text) : async {
    #ok : [Text];
    #err : Text;
  } {
    assert caller == parent;
    await SlackWrapper.getChannelMembers(token, channel);
  };

  // ============================================
  // HTTP Wrapper Test Methods
  // ============================================

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

  /// Like testMessageHandler, but pre-seeds the context with a real Slack bot token
  /// and Groq API key so the full happy-path (LLM call → Slack post) can be exercised
  /// and captured with the cassette recording system.
  public shared ({ caller }) func testMessageHandlerWithSecrets(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
    },
    botToken : Text,
    groqApiKey : Text,
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await MessageHandler.handle(workspaceId, msg, ctxWithSecrets(botToken, groqApiKey));
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

  public shared ({ caller }) func testAssistantThreadEventHandler(
    workspaceId : Nat,
    thread : {
      eventType : { #threadStarted; #threadContextChanged };
      userId : Text;
      channelId : Text;
      threadTs : Text;
      eventTs : Text;
      context : NormalizedEventTypes.AssistantThreadContext;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    assert caller == parent;
    await AssistantThreadHandler.handle(workspaceId, thread, emptyCtx());
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
