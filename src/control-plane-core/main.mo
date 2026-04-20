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
import Error "mo:core/Error";
import Types "./types";
import AgentModel "./models/agent-model";
import ChannelHistoryModel "./models/channel-history-model";
import SlackUserModel "./models/slack-user-model";
import WorkspaceModel "./models/workspace-model";
import SecretModel "./models/secret-model";
import KeyDerivationService "./services/key-derivation-service";
import Constants "./constants";
import HttpCertification "./utilities/http-certification";
import EventStoreModel "./models/event-store-model";
import EventRouter "./events/event-router";
import SlackAdapter "./events/slack-adapter";
import Logger "./utilities/logger";
import ClearKeyCacheRunner "./timers/clear-key-cache-runner";
import ProcessedEventsCleanupRunner "./timers/processed-events-cleanup-runner";
import WeeklyReconciliationRunner "./timers/weekly-reconciliation-runner";
import ChannelHistoryPruneRunner "./timers/channel-history-prune-runner";
import TurnCleanupRunner "./timers/turn-cleanup-runner";
import EngineTopUpRunner "./timers/engine-topup-runner";
import SlackEventIntakeService "./services/slack-event-intake-service";
import SessionModel "./models/session-model";
import ExecutionTokenService "./services/execution-token-service";
import ExecutionApiService "./services/execution-api-service";
import ExecutionTypes "./types/execution";
import SlackWrapper "./wrappers/slack-wrapper";
import InternalEngine "../internal-engine/main";

persistent actor class OpenOrgBackend() {
  // ============================================
  // State
  // ============================================

  // Channel history store: channel-keyed Slack message timeline for LLM context assembly.
  let channelHistoryStore = ChannelHistoryModel.empty();
  let secrets = SecretModel.initState(); // Encrypted secrets and audit logs per workspace
  transient var keyCache : KeyDerivationService.KeyCache = KeyDerivationService.clearCache(); // Cache of derived encryption keys per workspace
  var lastClearTimestamp : Int = Time.now(); // Track last time cache was cleared
  let agentRegistry = AgentModel.defaultState(); // Global agent registry state, pre-seeded with the default workspace-admin agent
  // Slack user state (cache: Slack user ID → SlackUserEntry; changeLog: audit trail)
  let slackUsers = SlackUserModel.emptyState();

  // Workspace channel anchors (workspace ID → WorkspaceRecord with admin/member Slack channel IDs)
  // Workspace 0 is the org workspace; its adminChannelId IS the org-admin channel anchor.
  let workspaces = WorkspaceModel.emptyState();

  // HTTP certification state (skip-certification for query responses)
  var httpCertStore = HttpCertification.initStore();

  // Event store state (Slack events, per-event timer dispatch)
  let eventStore = EventStoreModel.empty();
  var lastProcessedCleanupTimestamp : Int = Time.now(); // Track last time processed events were purged
  var lastWeeklyReconciliationTimestamp : Int = Time.now(); // Track last time weekly reconciliation ran
  var lastChannelHistoryPruneTimestamp : Int = Time.now(); // Track last time channel history store was pruned
  var lastTurnCleanupTimestamp : Int = Time.now(); // Track last time turn cleanup ran

  // Agent session stores (sessions, turns, traces)
  let sessionStores = SessionModel.emptyStores();

  // Execution token store (engine ↔ Core authorization)
  let executionTokenStore = ExecutionTokenService.emptyStore();

  // Execution API service (instantiated once with all deps captured in class scope)
  transient let executionApiService = ExecutionApiService.Service({
    tokenStore = executionTokenStore;
    workspaces;
    agentRegistry;
    eventStore;
    sessionStores;
  });

  // Internal engine canister principal — set when engine is spawned (Phase 6)
  var internalEnginePrincipal : ?Principal = null;

  // Internal engine canister reference — set when engine is spawned or re-acquired on upgrade
  var internalEngine : ?InternalEngine.InternalEngine = null;

  // Track last engine top-up for the timer runner
  var lastEngineTopUpTimestamp : Int = Time.now();

  // Monotonic counter for generating unique envelope IDs
  var nextEnvelopeId : Nat = 0;

  // Scheduled timer tracking — transient so it resets on upgrade (matching IC timer wipe).
  // Populated by scheduleAll() during init and postupgrade.
  // Key = Timer.TimerId (unique), value = entry metadata.
  transient let timerSchedule = Map.empty<Nat, { name : Text; expectedRunNs : Int }>();

  // ============================================
  // Engine Lifecycle
  // ============================================

  /// Spawn a new engine canister with initial cycles.
  private func deployEngine() : async InternalEngine.InternalEngine {
    await (with cycles = Constants.ENGINE_SPAWN_CYCLES) InternalEngine.InternalEngine();
  };

  /// Ensure the engine canister exists, spawning it lazily on first need.
  private func ensureEngine() : async InternalEngine.InternalEngine {
    switch (internalEngine) {
      case (?e) { e };
      case null {
        let e = await deployEngine();
        internalEngine := ?e;
        internalEnginePrincipal := ?Principal.fromActor(e);
        Logger.log(#info, ?"EngineLifecycle", "Engine canister spawned: " # Principal.toText(Principal.fromActor(e)));
        e;
      };
    };
  };

  /// Generate a unique envelope ID for engine dispatch.
  private func generateEnvelopeId() : Text {
    let id = nextEnvelopeId;
    nextEnvelopeId += 1;
    "env_" # Nat.toText(id);
  };

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
        name = "channel-history-prune";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastChannelHistoryPruneTimestamp };
        setLastRun = func(t : Int) { lastChannelHistoryPruneTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          ChannelHistoryPruneRunner.run(channelHistoryStore);
        };
      },
      {
        name = "turn-cleanup";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastTurnCleanupTimestamp };
        setLastRun = func(t : Int) { lastTurnCleanupTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          switch (TurnCleanupRunner.run(sessionStores)) {
            case (#ok(_)) { #ok };
            case (#err(e)) { #err(e) };
          };
        };
      },
      {
        name = "engine-topup";
        interval = Constants.SEVEN_DAYS_NS;
        getLastRun = func() : Int { lastEngineTopUpTimestamp };
        setLastRun = func(t : Int) { lastEngineTopUpTimestamp := t };
        wrappedRun = func() : async { #ok; #err : Text } {
          await EngineTopUpRunner.run(internalEnginePrincipal);
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
      channelHistory = channelHistoryStore;
      agentRegistry;
      slackUsers;
      workspaces;
      eventStore;
      sessionStores;
      executionTokenStore;
      generateEnvelopeId;
      dispatchToEngine = func(envelope : ExecutionTypes.ExecutionEnvelope) : async {
        #ok;
        #err : Text;
      } {
        let e = await ensureEngine();
        await e.execute(envelope);
      };
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

    // Propagate upgrade to engine canister (if spawned).
    switch (internalEngine) {
      case (?e) {
        ignore Timer.setTimer<system>(
          #seconds 0,
          func() : async () {
            try {
              let upgraded = await (system InternalEngine.InternalEngine)(#upgrade e)();
              internalEngine := ?upgraded;
              Logger.log(#info, ?"EngineLifecycle", "Engine canister upgrade propagated");
            } catch (err) {
              Logger.log(#error, ?"EngineLifecycle", "Engine upgrade failed: " # Error.message(err));
            };
          },
        );
      };
      case null {};
    };
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
    // Validate that the secret is an org-critical secret (OrgCriticalSecretId subset)
    switch (secretId) {
      case (#openRouterApiKey or #slackBotToken or #slackSigningSecret) {};
      case (_) {
        return #err("Only org-critical secrets may be stored via this method.");
      };
    };
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    switch (SecretModel.storeSecret(secrets, encryptionKey, 0, secretId, value, { slackUserId = null; agentId = null; operation = "storeOrgCriticalSecrets" })) {
      case (#err(msg)) { #err(msg) };
      case (#ok(())) {
        if (secretId == #slackBotToken) {
          ignore Timer.setTimer<system>(
            #seconds 0,
            func() : async () {
              switch (await WeeklyReconciliationRunner.run(keyCache, secrets, slackUsers, workspaces)) {
                case (#ok(_)) {};
                case (#err(e)) {
                  Logger.log(#error, ?"StoreSecret", "WeeklyReconciliationRunner failed after slackBotToken store: " # e);
                };
              };
            },
          );
        };
        #ok(());
      };
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
  // Execution API (engine → Core)
  // ============================================

  /// Single endpoint for engine-to-Core communication.
  /// The engine sends method + path + JSON body; path encodes the resource and optional ID.
  /// Transport-level guard: only the internal engine canister principal may call this.
  public shared ({ caller }) func executionApi(
    method : { #get; #post; #delete },
    path : Text,
    body : Text,
  ) : async { #ok : Text; #err : Text } {
    switch (internalEnginePrincipal) {
      case (null) {};
      case (?expected) {
        if (caller != expected) {
          return #err("Unauthorized: caller " # Principal.toText(caller) # " is not the internal engine canister");
        };
      };
    };
    let { response; asyncEffects } = executionApiService.handleRequest(method, path, body);

    // Schedule async processing for any async effects produced by the request
    for (effect in asyncEffects.vals()) {
      ignore Timer.setTimer<system>(
        #seconds 0,
        func() : async () {
          await processExecutionAsyncEffect(effect);
        },
      );
    };

    response;
  };

  /// Process a single execution async effect — posts results to Slack and completes turns.
  private func processExecutionAsyncEffect(effect : ExecutionTypes.AsyncEffect) : async () {
    let (envelopeId, turnId, humanSummary) = switch (effect) {
      case (#milestone(m)) { (m.envelopeId, m.turnId, m.humanSummary) };
      case (#complete(c)) { (c.envelopeId, c.turnId, c.humanSummary) };
    };

    // Look up the turn to get source context
    let turn = switch (SessionModel.findTurn(sessionStores, turnId)) {
      case (?t) { t };
      case null {
        Logger.log(#error, ?"ExecutionAsyncEffect", "Turn not found: " # turnId # " (envelope=" # envelopeId # ")");
        return;
      };
    };

    // Look up agent for metadata and workspace context
    let agent = switch (AgentModel.lookupById(agentRegistry, turn.agentId)) {
      case (?a) { a };
      case null {
        Logger.log(#error, ?"ExecutionAsyncEffect", "Agent not found: " # Nat.toText(turn.agentId));
        return;
      };
    };

    // For non-Slack sources (timer, GitHub, etc.), fall back to the agent's workspace
    // admin channel so execution is observable rather than silently lost.
    // ts and threadTs are null since there is no parent message to thread under.
    let (channelId, ts, threadTs) = switch (turn.sourceRef) {
      case (?#slack(s)) { (s.channelId, s.ts, s.threadTs) };
      case (_) {
        let adminChannel = switch (WorkspaceModel.getWorkspace(workspaces, agent.ownedBy)) {
          case (?ws) { ws.adminChannelId };
          case null { null };
        };
        switch (adminChannel) {
          case (?ch) { (ch, "", null) };
          case null {
            Logger.log(#error, ?"ExecutionAsyncEffect", "No admin channel for non-Slack turn " # turnId # " — cannot post result");
            return;
          };
        };
      };
    };

    // Derive bot token
    let orgKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let botToken = switch (
      SecretModel.resolvePlatformSecret(
        secrets,
        orgKey,
        null,
        #slackBotToken,
        {
          slackUserId = null;
          agentId = null;
          operation = "async-effect:bot-token";
        },
      )
    ) {
      case (?t) { t };
      case null {
        Logger.log(#error, ?"ExecutionAsyncEffect", "Bot token not available for turn " # turnId);
        return;
      };
    };

    // Build metadata matching the message-handler pattern
    let metadata : ?Types.AgentMessageMetadata = ?{
      event_type = "looping_agent_message";
      event_payload = {
        parent_agent = agent.config.name;
        parent_ts = ts;
        parent_channel = channelId;
        turn_id = turnId;
      };
    };

    switch (effect) {
      case (#milestone(_m)) {
        // Post milestone update to Slack thread
        let milestoneText = humanSummary;
        switch (await SlackWrapper.postMessage(botToken, channelId, milestoneText, threadTs, metadata)) {
          case (#ok(_)) {};
          case (#err(e)) {
            Logger.log(#error, ?"ExecutionAsyncEffect", "Milestone post failed for turn " # turnId # ": " # e);
          };
        };
      };
      case (#complete(c)) {
        // Post final response
        let replyText = humanSummary;
        switch (await SlackWrapper.postMessage(botToken, channelId, replyText, threadTs, metadata)) {
          case (#ok({ ts = replyTs; channel = _ })) {
            SessionModel.appendTrace(
              sessionStores,
              turnId,
              #slackPost({
                channelId;
                threadTs;
                ts = replyTs;
              }),
            );
          };
          case (#err(e)) {
            Logger.log(#error, ?"ExecutionAsyncEffect", "Reply post failed for turn " # turnId # ": " # e);
          };
        };

        // Map engine execution status to turn status and cost
        let (turnStatus, errorSummary) = switch (c.status) {
          case (#completed) { (#succeeded, null) };
          case (#failed(reason)) { (#failed, ?reason) };
          case (#roundLimitReached) { (#failed, ?"Round limit reached") };
        };

        let turnCost : ?SessionModel.TurnCost = ?{
          promptTokens = c.stats.inputTokens;
          completionTokens = c.stats.outputTokens;
          estimatedMicroUnits = 0; // TODO: compute from model pricing
        };

        SessionModel.completeTurn(sessionStores, turnId, turnStatus, turnCost, errorSummary);
      };
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
    let signingSecret = switch (SecretModel.resolvePlatformSecret(secrets, encryptionKey, null, #slackSigningSecret, { slackUserId = null; agentId = null; operation = "slack-signature-verify" })) {
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
