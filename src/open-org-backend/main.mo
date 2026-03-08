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
import ClearKeyCacheRunner "./timers/clear-key-cache-runner";
import MetricRetentionRunner "./timers/metric-retention-runner";
import ProcessedEventsCleanupRunner "./timers/processed-events-cleanup-runner";
import WeeklyReconciliationRunner "./timers/weekly-reconciliation-runner";
import ConversationPruneRunner "./timers/conversation-prune-runner";
import SlackEventIntakeService "./services/slack-event-intake-service";

persistent actor class OpenOrgBackend() {
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

  // Scheduled timer tracking — transient so it resets on upgrade (matching IC timer wipe).
  // Populated by scheduleAll() during init and postupgrade.
  // Key = Timer.TimerId (unique), value = entry metadata.
  transient let timerSchedule = Map.empty<Nat, { name : Text; expectedRunNs : Int }>();

  // ============================================
  // Timer Management
  // ============================================

  // Timer registry — each entry defines a recurring timer with its interval,
  // last-run timestamp reader/writer, and a wrappedRun closure that calls the
  // runner with the right arguments and returns a normalized Result.
  // To add a new timer: append an entry here and create the timestamp variable.
  // Init and postupgrade iterate this list automatically via scheduleAll().
  private type TimerRegistryEntry = {
    name : Text;
    interval : Nat;
    getLastRun : () -> Int;
    setLastRun : (Int) -> ();
    wrappedRun : () -> async { #ok; #err : Text };
  };

  private func timerRegistry() : [TimerRegistryEntry] {
    [
      {
        name = "clear-key-cache";
        interval = Constants.THIRTY_DAYS_NS;
        getLastRun = func() : Int { lastClearTimestamp };
        setLastRun = func(t : Int) { lastClearTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          switch (ClearKeyCacheRunner.run()) {
            case (#ok(cache)) { keyCache := cache; #ok };
            case (#err(e)) { #err(e) };
          };
        };
      },
      {
        name = "metric-retention";
        interval = Constants.THIRTY_DAYS_NS;
        getLastRun = func() : Int { lastRetentionCleanupTimestamp };
        setLastRun = func(t : Int) { lastRetentionCleanupTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          switch (MetricRetentionRunner.run(metricDatapoints, metricsRegistry)) {
            case (#ok(_)) { #ok };
            case (#err(e)) { #err(e) };
          };
        };
      },
      {
        name = "processed-events-cleanup";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastProcessedCleanupTimestamp };
        setLastRun = func(t : Int) { lastProcessedCleanupTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          ProcessedEventsCleanupRunner.run(eventStore);
        };
      },
      {
        name = "weekly-reconciliation";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastWeeklyReconciliationTimestamp };
        setLastRun = func(t : Int) { lastWeeklyReconciliationTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          switch (await WeeklyReconciliationRunner.run(keyCache, secrets, slackUsers, workspaces)) {
            case (#ok(_)) { #ok };
            case (#err(e)) { #err(e) };
          };
        };
      },
      {
        name = "conversation-prune";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastConversationPruneTimestamp };
        setLastRun = func(t : Int) { lastConversationPruneTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          ConversationPruneRunner.run(conversationStore);
        };
      },
    ];
  };

  /// Build a recurring timer callback from a registry entry.
  /// The callback reschedules itself before doing work (trap-safe),
  /// records the new timer ID, runs the runner, and updates the timestamp.
  private func makeTimerCallback(config : TimerRegistryEntry) : () -> async () {
    func cb() : async () {
      let id = Timer.setTimer<system>(#nanoseconds(config.interval), cb);
      recordTimer(id, config.name, config.interval);
      switch (await config.wrappedRun()) {
        case (#ok) {};
        case (#err(e)) {
          Logger.log(#error, ?"TimerRunner", "Runner '" # config.name # "' failed: " # e);
        };
      };
      config.setLastRun(Time.now());
    };
    cb;
  };

  /// Record a timer ID in the transient schedule.
  private func recordTimer(timerId : Nat, name : Text, intervalNs : Nat) {
    Map.add(
      timerSchedule,
      Nat.compare,
      timerId,
      {
        name;
        expectedRunNs = Time.now() + intervalNs;
      },
    );
  };

  /// Schedule all recurring timers. Used by both init and postupgrade.
  /// `delayFn` computes the initial delay per entry (full interval for init,
  /// remaining time for postupgrade).
  private func scheduleAll<system>(delayFn : (TimerRegistryEntry) -> Nat) {
    for (config in timerRegistry().vals()) {
      let delay = delayFn(config);
      let cb = makeTimerCallback(config);
      let id = Timer.setTimer<system>(#nanoseconds(delay), cb);
      Map.add(
        timerSchedule,
        Nat.compare,
        id,
        {
          name = config.name;
          expectedRunNs = Time.now() + delay;
        },
      );
    };
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

  // ============================================
  // Canister Init and Postupgrade
  // ============================================

  // Certify HTTP endpoints on first install
  certifyHttpEndpoints();

  // Schedule all recurring timers on first install.
  // Subsequent upgrades will wipe these timers; postupgrade re-creates them.
  scheduleAll<system>(func(config : TimerRegistryEntry) : Nat { config.interval });

  // System hook called after every upgrade
  system func postupgrade() {
    let now = Time.now();

    // Restart each recurring timer with its remaining time
    scheduleAll<system>(
      func(config : TimerRegistryEntry) : Nat {
        let elapsed = now - config.getLastRun();
        if (elapsed >= config.interval) { 0 } else {
          Nat.fromInt(config.interval - elapsed);
        };
      }
    );

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
    if (not Principal.isController(caller)) {
      return #err("Unauthorized: caller is not a canister controller.");
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
  // Timer Observability
  // ============================================

  /// Return the current timer schedule. Controller-only.
  public shared query ({ caller }) func getScheduledTimers() : async {
    #ok : [{ timerId : Nat; name : Text; expectedRunNs : Int }];
    #err : Text;
  } {
    if (not Principal.isController(caller)) {
      return #err("Unauthorized: caller is not a canister controller.");
    };
    #ok(
      Array.map<(Nat, { name : Text; expectedRunNs : Int }), { timerId : Nat; name : Text; expectedRunNs : Int }>(
        Map.toArray(timerSchedule),
        func((id, entry)) {
          {
            timerId = id;
            name = entry.name;
            expectedRunNs = entry.expectedRunNs;
          };
        },
      )
    );
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
      case (#event_callback(_)) {
        switch (SlackEventIntakeService.processEventBody(eventStore, bodyText)) {
          case (#skipped(_) or #duplicate) {};
          case (#enqueued(eid)) {
            // Schedule a per-event timer to process immediately
            ignore Timer.setTimer<system>(
              #seconds 0,
              func() : async () {
                await makeEventProcessor(eid);
              },
            );
          };
          case (#parseError(e)) {
            // Should not happen (envelope already parsed above), but handle defensively
            Logger.log(#error, ?"SlackWebhook", "Unexpected parse error in intake: " # e);
          };
          case (#notEventCallback) {
            // Should not happen (we matched #event_callback above)
            Logger.log(#warn, ?"SlackWebhook", "Unexpected non-event-callback in event_callback branch");
          };
        };
        respondWithText(200, "ok");
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
