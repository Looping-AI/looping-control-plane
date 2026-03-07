import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Runtime "mo:core/Runtime";
import Types "./types";
import AgentModel "./models/agent-model";
import ConversationModel "./models/conversation-model";
import SlackUserModel "./models/slack-user-model";
import WorkspaceModel "./models/workspace-model";
import SecretModel "./models/secret-model";
import KeyDerivationService "./services/key-derivation-service";
import McpToolRegistry "./tools/mcp-tool-registry";
import Constants "./constants";
import MetricModel "./models/metric-model";
import ValueStreamModel "./models/value-stream-model";
import ObjectiveModel "./models/objective-model";
import HttpCertification "./utilities/http-certification";
import EventStoreModel "./models/event-store-model";
import EventRouter "./events/event-router";
import SlackAdapter "./events/slack-adapter";
import Logger "./utilities/logger";
import WeeklyReconciliationService "./services/weekly-reconciliation-service";

persistent actor class OpenOrgBackend() = this {
  // ============================================
  // State
  // ============================================

  // Channel-keyed conversation store (Phase 1.4): replaces the old (workspaceId, agentId)-keyed
  // `conversations` map and the workspaceId-keyed `adminConversations` map.
  let conversationStore = ConversationModel.empty();
  let secrets = Map.empty<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>(); // Encrypted secrets per workspace
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys per workspace
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared
  var lastRetentionCleanupTimestamp : Int = Time.now(); // Track last time retention cleanup ran
  let agentRegistry = AgentModel.defaultState(); // Global agent registry state, pre-seeded with the default workspace-admin agent
  let mcpToolRegistry = McpToolRegistry.empty(); // MCP tools registry (dynamic, runtime configurable)

  // Slack user state (cache: Slack user ID → SlackUserEntry; changeLog: audit trail)
  let slackUsers = SlackUserModel.emptyState();

  // Workspace channel anchors (workspace ID → WorkspaceRecord with admin/member Slack channel IDs)
  // Workspace 0 is the org workspace; its adminChannelId IS the org-admin channel anchor.
  let workspaces = WorkspaceModel.emptyState();

  // Metrics and Value Streams state (org-level metrics, workspace-scoped value streams and objectives)
  let metricsRegistry = MetricModel.emptyRegistry(); // Org-level metric definitions (nextMetricId, registry)
  let metricDatapoints = MetricModel.emptyDatapoints(); // Datapoints for each metric
  let workspaceValueStreams = Map.fromArray<Nat, ValueStreamModel.WorkspaceValueStreamsState>([(0, ValueStreamModel.emptyWorkspaceState())], Nat.compare);
  let workspaceObjectives = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>([(0, Map.empty<Nat, ObjectiveModel.ValueStreamObjectivesState>())], Nat.compare);

  // HTTP certification state (skip-certification for query responses)
  var httpCertStore = HttpCertification.initStore();

  // Event store state (Slack events, per-event timer dispatch)
  let eventStore = EventStoreModel.empty();
  var lastProcessedCleanupTimestamp : Int = Time.now(); // Track last time processed events were purged
  var lastWeeklyReconciliationTimestamp : Int = Time.now(); // Track last time weekly reconciliation ran
  var lastConversationPruneTimestamp : Int = Time.now(); // Track last time conversation store was pruned

  // ============================================
  // Timer Management
  // ============================================

  // Timer registry — each entry defines a recurring timer with its interval,
  // last-run timestamp reader, and callback. To add a new timer, append an
  // entry here and create the corresponding callback + timestamp variable.
  // Init and postupgrade iterate this list automatically.
  private func timerRegistry() : [{
    interval : Nat;
    getLastRun : () -> Int;
    callback : () -> async ();
  }] {
    [
      {
        interval = Constants.THIRTY_DAYS_NS;
        getLastRun = func() : Int { lastClearTimestamp };
        callback = clearKeyCacheTimer;
      },
      {
        interval = Constants.THIRTY_DAYS_NS;
        getLastRun = func() : Int { lastRetentionCleanupTimestamp };
        callback = metricRetentionCleanupTimer;
      },
      {
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastProcessedCleanupTimestamp };
        callback = processedEventsCleanupTimer;
      },
      {
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastWeeklyReconciliationTimestamp };
        callback = weeklyReconciliationTimer;
      },
      {
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastConversationPruneTimestamp };
        callback = conversationPruneTimer;
      },
    ];
  };

  // Clear Cache Timer function
  private func clearKeyCacheTimer() : async () {
    // Reschedule before doing work so the timer survives a trap
    ignore Timer.setTimer<system>(
      #nanoseconds(Constants.THIRTY_DAYS_NS),
      clearKeyCacheTimer,
    );

    keyCache := KeyDerivationService.clearCache();
    lastClearTimestamp := Time.now();
  };

  // Metric Datapoints Retention Cleanup Timer
  // Runs monthly to purge datapoints older than their metric's retention period
  private func metricRetentionCleanupTimer() : async () {
    // Reschedule before doing work so the timer survives a trap
    ignore Timer.setTimer<system>(
      #nanoseconds(Constants.THIRTY_DAYS_NS),
      metricRetentionCleanupTimer,
    );

    ignore MetricModel.purgeOldDatapoints(metricDatapoints, metricsRegistry);
    lastRetentionCleanupTimestamp := Time.now();
  };

  // Register HTTP paths that skip response verification
  private func certifyHttpEndpoints() {
    HttpCertification.certifySkipFallbackPath(httpCertStore, "/");
  };

  // Per-event timer callback factory — returns an async closure that processes one event by ID
  private func makeEventProcessor(eventId : Text) : async () {
    let ctx : EventRouter.EventProcessingContext = {
      secrets;
      keyCache;
      conversationStore;
      mcpToolRegistry;
      agentRegistry;
      workspaceValueStreams;
      workspaceObjectives;
      metricsRegistry;
      metricDatapoints;
      slackUsers;
      workspaces;
      eventStore;
    };
    await EventRouter.processSingleEvent(eventStore, eventId, ctx);
  };

  // Processed Events Cleanup Timer
  // Runs every 7 days to:
  //   1. Detect unprocessed events stuck for > 1h and move them to failed
  //   2. Purge old processed events (> 7 days)
  //   3. Purge old failed events (> 30 days)
  private func processedEventsCleanupTimer() : async () {
    // Reschedule before doing work so the timer survives a trap
    ignore Timer.setTimer<system>(
      #nanoseconds(Constants.SEVEN_DAYS_NS),
      processedEventsCleanupTimer,
    );

    // 1. Detect and fail stale unprocessed events (enqueuedAt > 1 hour ago)
    let staleIds = EventStoreModel.failStaleUnprocessed(eventStore);
    if (staleIds.size() > 0) {
      let idList = Array.foldLeft<Text, Text>(
        staleIds,
        "",
        func(acc, id) {
          if (acc == "") id else acc # ", " # id;
        },
      );
      Logger.log(#warn, ?"EventStore", "Failed " # Nat.toText(staleIds.size()) # " stale unprocessed event(s): " # idList);
    };

    // 2. Purge old processed events (> 7 days)
    ignore EventStoreModel.purgeProcessed(eventStore);

    // 3. Purge old failed events (> 30 days)
    ignore EventStoreModel.purgeOldFailed(eventStore);

    lastProcessedCleanupTimestamp := Time.now();
  };

  // Weekly Reconciliation Timer
  // Runs every 7 days (aligned with Sunday if the first deployment happens on a Sunday).
  // Performs a full users.list + conversations.members sweep and verifies all tracked
  // channel anchors. Notifies admins / the Primary Owner about any channels that have
  // gone missing since the last run.
  private func weeklyReconciliationTimer() : async () {
    // Reschedule before doing work so the timer survives a trap
    ignore Timer.setTimer<system>(
      #nanoseconds(Constants.SEVEN_DAYS_NS),
      weeklyReconciliationTimer,
    );

    // Resolve the bot token from workspace 0 secrets (global Slack integration secret).
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let workspaceSecrets = Map.get(secrets, Nat.compare, 0);
    switch (SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, #slackBotToken)) {
      case (null) {
        Logger.log(
          #warn,
          ?"WeeklyReconciliation",
          "No Slack bot token found for workspace 0 — skipping weekly reconciliation.",
        );
      };
      case (?token) {
        // Ignore summary since service already has logging
        ignore await WeeklyReconciliationService.run(
          token,
          slackUsers,
          workspaces,
        );
      };
    };

    lastWeeklyReconciliationTimestamp := Time.now();
  };

  // Conversation Store Prune Timer (Phase 1.4)
  // Runs every 7 days. Drops timeline entries where ALL messages are older than
  // CONVERSATION_RETENTION_SECS (30 days). The old-thread grace rule preserves
  // a thread entry if any message in it falls within the retention window.
  private func conversationPruneTimer() : async () {
    // Reschedule before doing work so the timer survives a trap
    ignore Timer.setTimer<system>(
      #nanoseconds(Constants.SEVEN_DAYS_NS),
      conversationPruneTimer,
    );

    let nowSecs : Nat = Int.abs(Time.now() / 1_000_000_000);
    let cutoffSecs : Nat = if (nowSecs > Constants.CONVERSATION_RETENTION_SECS) {
      Nat.sub(nowSecs, Constants.CONVERSATION_RETENTION_SECS);
    } else { 0 };
    ConversationModel.pruneAll(conversationStore, cutoffSecs);
    lastConversationPruneTimestamp := Time.now();
  };

  // ============================================
  // Canister Init and Postupgrade
  // ============================================

  // Certify HTTP endpoints on first install
  certifyHttpEndpoints();

  // Schedule all recurring timers on first install.
  // Subsequent upgrades will wipe these timers; postupgrade re-creates them.
  for (config in timerRegistry().vals()) {
    ignore Timer.setTimer<system>(#nanoseconds(config.interval), config.callback);
  };

  // System hook called after every upgrade
  system func postupgrade() {
    let now = Time.now();

    // Restart each recurring timer with its remaining time
    for (config in timerRegistry().vals()) {
      let elapsed = now - config.getLastRun();
      let delay : Nat = if (elapsed >= config.interval) { 0 } else {
        Nat.fromInt(config.interval - elapsed);
      };
      ignore Timer.setTimer<system>(#nanoseconds(delay), config.callback);
    };

    // Re-certify HTTP endpoints (IC clears CertifiedData on upgrade)
    // Start from empty store to ensure consistency if paths changed in certifyHttpEndpoints()
    httpCertStore := HttpCertification.initStore();
    certifyHttpEndpoints();
  };

  // ============================================
  // Org-Critical Secrets
  // ============================================

  /// Store an org-critical secret (encrypted at rest). Only the org owner may call this.
  /// Secrets are stored under workspace 0 (the org workspace) using the workspace
  /// encryption key derived from ICP's Threshold Schnorr signatures.
  public shared ({ caller }) func storeOrgCriticalSecrets(secretId : Types.SecretId, value : Text) : async {
    #ok : ();
    #err : Text;
  } {
    // Authorize by checking that the caller is a controller of this canister
    let ic = actor "aaaaa-aa" : actor {
      canister_status : ({ canister_id : Principal }) -> async {
        settings : { controllers : [Principal] };
      };
    };
    let status = await ic.canister_status({
      canister_id = Principal.fromActor(this);
    });
    switch (Array.find<Principal>(status.settings.controllers, func(p) { Principal.equal(p, caller) })) {
      case (null) {
        return #err("Unauthorized: caller is not a canister controller.");
      };
      case (?_) {};
    };
    if (Text.trim(value, #char ' ') == "") {
      return #err("Secret value cannot be empty.");
    };
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    switch (SecretModel.storeSecret(secrets, encryptionKey, 0, secretId, value)) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) { #ok(()) };
    };
  };

  // ============================================
  // HTTP Incoming Requests (Webhooks)
  // ============================================

  // Helper to construct a standard text response
  private func respondWithText(statusCode : Nat16, message : Text) : Types.HttpResponse {
    {
      status_code = statusCode;
      headers = [("content-type", "text/plain")];
      body = Text.encodeUtf8(message);
      upgrade = null;
    };
  };

  // Helper to construct a text response with certification headers
  private func respondWithTextAndCertificate(statusCode : Nat16, message : Text, url : Text) : Types.HttpResponse {
    let certHeaders = HttpCertification.getSkipCertificationHeaders(httpCertStore, url);
    {
      status_code = statusCode;
      headers = Array.concat<(Text, Text)>([("content-type", "text/plain")], certHeaders);
      body = Text.encodeUtf8(message);
      upgrade = null;
    };
  };

  /// Query entry point for all incoming HTTP requests.
  /// POST requests are upgraded to update calls so they can mutate state.
  /// GET requests return a simple status message.
  public query func http_request(req : Types.HttpRequest) : async Types.HttpResponse {
    if (req.method == "POST") {
      {
        status_code = 200;
        headers = [];
        body = Blob.fromArray([]);
        upgrade = ?true;
      };
    } else if (req.method == "GET") {
      respondWithTextAndCertificate(200, "Looping AI API Server", req.url);
    } else {
      respondWithTextAndCertificate(400, "Bad Request", req.url);
    };
  };

  /// Update entry point called when http_request returns upgrade = ?true.
  /// Handles Slack webhook payloads: verifies signature, parses events, enqueues for processing.
  /// Responds immediately (no awaits for LLM calls) to avoid Slack retries.
  public func http_request_update(req : Types.HttpUpdateRequest) : async Types.HttpResponse {
    // Ensure this is a request to the Slack webhook endpoint (accept query parameters)
    if (not (Text.startsWith(req.url, #text "/webhook/slack") or Text.startsWith(req.url, #text "/webhook/slack/"))) {
      return respondWithText(400, "Unrecognized path");
    };

    let bodyText = switch (Text.decodeUtf8(req.body)) {
      case (?text) { text };
      case (null) {
        return respondWithText(400, "Invalid request body encoding");
      };
    };

    // Parse the envelope to determine type
    let envelope = switch (SlackAdapter.parseEnvelope(bodyText)) {
      case (#err(e)) {
        Logger.log(#error, ?"SlackWebhook", "Failed to parse envelope: " # e);
        return respondWithText(400, "Invalid payload. Error: " # e);
      };
      case (#ok(env)) { env };
    };

    // Handle url_verification (challenge handshake) — no signature check needed
    switch (envelope) {
      case (#url_verification(verification)) {
        return respondWithText(200, verification.challenge);
      };
      case _ {};
    };

    // For all other event types, verify the Slack signature.
    // Check headers first (fast path), then derive the encryption key to read
    // the signing secret from the encrypted store (workspace 0).
    let signature = switch (SlackAdapter.getHeader(req.headers, "X-Slack-Signature")) {
      case (null) {
        return respondWithText(401, "Missing signature");
      };
      case (?sig) { sig };
    };
    let timestamp = switch (SlackAdapter.getHeader(req.headers, "X-Slack-Request-Timestamp")) {
      case (null) {
        return respondWithText(401, "Missing timestamp");
      };
      case (?ts) { ts };
    };

    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let workspaceSecrets = Map.get(secrets, Nat.compare, 0);
    let signingSecret = switch (SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, #slackSigningSecret)) {
      case (null) {
        Logger.log(#error, ?"SlackWebhook", "No Slack signing secret configured");
        return respondWithText(401, "Slack signing secret not configured");
      };
      case (?secret) { secret };
    };

    if (not SlackAdapter.verifySignature(signingSecret, signature, timestamp, bodyText)) {
      Logger.log(#warn, ?"SlackWebhook", "Signature verification failed");
      return respondWithText(401, "Invalid signature");
    };

    // Signature verified — process the envelope
    switch (envelope) {
      case (#url_verification(_)) {
        Runtime.unreachable(); // handled before and returned
      };
      case (#event_callback(callback)) {
        // Normalize and enqueue the event
        switch (SlackAdapter.normalizeEvent(callback)) {
          case (#err(reason)) {
            Logger.log(#_debug, ?"SlackWebhook", "Skipping event: " # reason);
            // Still return 200 so Slack doesn't retry
            respondWithText(200, "ok");
          };
          case (#ok(event)) {
            switch (EventStoreModel.enqueue(eventStore, event)) {
              case (#duplicate) {
                Logger.log(#_debug, ?"EventStore", "Duplicate event: " # event.eventId);
              };
              case (#ok) {
                Logger.log(#_debug, ?"EventStore", "Enqueued event: " # event.eventId);
                // Schedule a per-event timer to process immediately
                let eid = event.eventId;
                ignore Timer.setTimer<system>(
                  #seconds 0,
                  func() : async () {
                    await makeEventProcessor(eid);
                  },
                );
              };
            };
            respondWithText(200, "ok");
          };
        };
      };
      case (#app_rate_limited(rateLimited)) {
        let minuteStr = Int.toText(rateLimited.minute_rate_limited);
        let logMsg = "Rate-limiting events for team " # rateLimited.team_id # " at minute " # minuteStr;
        Logger.log(#warn, ?"SlackWebhook", logMsg);
        respondWithText(200, "ok");
      };
      case (#unknown(envelopeType)) {
        Logger.log(#warn, ?"SlackWebhook", "Unknown envelope type: " # envelopeType);
        respondWithText(200, "ok");
      };
    };
  };
};
