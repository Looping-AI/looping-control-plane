/// Slack Adapter
/// Parses raw JSON from Slack webhooks into typed SlackEnvelope / Event structures
/// Handles:
///   - url_verification (challenge handshake)
///   - event_callback (real events: app_mention, message)
///   - app_rate_limited
///   - Signature verification using HMAC-SHA256
///
/// Debug logging: when ENVIRONMENT is #local or #staging, raw payloads are
/// printed via Debug.print so they can be retrieved with `dfx canister logs`
/// and copy-pasted into test stubs.

import Text "mo:core/Text";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Json "mo:json";
import SlackEventTypes "./types/slack-event-types";
import NormalizedEventTypes "./types/normalized-event-types";
import Hmac "../utilities/hmac";
import Constants "../constants";
import Encryption "../utilities/encryption";
import Logger "../utilities/logger";
import Types "../types";

module {

  // ============================================
  // Payload Logging
  // ============================================

  /// Log raw payload for development/debugging
  /// Readable via `dfx canister logs <canister-id>`
  func logRawPayload(bodyText : Text) {
    if (Constants.LOG_SLACK_EVENTS) {
      Logger.log(#_debug, ?"SlackAdapterEventRaw", bodyText);
    };
  };

  // ============================================
  // Signature Verification
  // ============================================

  /// Verify Slack request signature using HMAC-SHA256
  ///
  /// Slack signs requests with: v0=HMAC-SHA256(signing_secret, "v0:{timestamp}:{body}")
  /// See: https://api.slack.com/authentication/verifying-requests-from-slack
  ///
  /// @param signingSecret - The Slack signing secret (from app settings)
  /// @param signature - The X-Slack-Signature header value
  /// @param timestamp - The X-Slack-Request-Timestamp header value
  /// @param body - The raw request body
  /// @returns true if the signature is valid
  public func verifySignature(
    signingSecret : Text,
    signature : Text,
    timestamp : Text,
    body : Text,
  ) : Bool {
    // Build the base string: "v0:{timestamp}:{body}"
    let baseString = "v0:" # timestamp # ":" # body;

    // Compute HMAC-SHA256
    let msgBytes = Encryption.textToBytes(baseString);
    let secretBytes = Encryption.textToBytes(signingSecret);
    let hmacResult = Hmac.compute(secretBytes, msgBytes);
    let expectedSignature = "v0=" # Hmac.bytesToHex(hmacResult);

    // Constant-time comparison to prevent timing attacks
    Text.equal(signature, expectedSignature);
  };

  /// Extract a header value by name (case-insensitive)
  public func getHeader(headers : [Types.HeaderField], name : Text) : ?Text {
    let lowerName = Text.toLower(name);
    for ((key, value) in headers.vals()) {
      if (Text.toLower(key) == lowerName) {
        return ?value;
      };
    };
    null;
  };

  // ============================================
  // JSON Parsing
  // ============================================

  /// Parse raw JSON body into a SlackEnvelope
  ///
  /// @param bodyText - Raw JSON string from the webhook
  /// @returns Parsed envelope or error message
  public func parseEnvelope(bodyText : Text) : {
    #ok : SlackEventTypes.SlackEnvelope;
    #err : Text;
  } {
    // Log raw payload for dev environments
    logRawPayload(bodyText);

    let json = switch (Json.parse(bodyText)) {
      case (#ok(j)) { j };
      case (#err(e)) {
        return #err("Failed to parse JSON: " # debug_show (e));
      };
    };

    // Determine envelope type
    let envelopeType = switch (Json.get(json, "type")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing or invalid 'type' field in envelope") };
    };

    switch (envelopeType) {
      case ("url_verification") {
        switch (parseUrlVerification(json)) {
          case (#ok(v)) { #ok(#url_verification(v)) };
          case (#err(e)) { #err(e) };
        };
      };
      case ("event_callback") {
        switch (parseEventCallback(json)) {
          case (#ok(cb)) { #ok(#event_callback(cb)) };
          case (#err(e)) { #err(e) };
        };
      };
      case ("app_rate_limited") {
        #ok(#app_rate_limited);
      };
      case (other) {
        #ok(#unknown(other));
      };
    };
  };

  /// Parse url_verification envelope
  func parseUrlVerification(json : Json.Json) : {
    #ok : SlackEventTypes.SlackUrlVerification;
    #err : Text;
  } {
    let challenge = switch (Json.get(json, "challenge")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'challenge' in url_verification") };
    };
    let token = switch (Json.get(json, "token")) {
      case (?#string(t)) { t };
      case _ { "" }; // Token is deprecated, not required
    };
    #ok({ challenge; token });
  };

  /// Parse event_callback envelope
  func parseEventCallback(json : Json.Json) : {
    #ok : SlackEventTypes.SlackEventCallback;
    #err : Text;
  } {
    let token = switch (Json.get(json, "token")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let teamId = switch (Json.get(json, "team_id")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'team_id' in event_callback") };
    };
    let apiAppId = switch (Json.get(json, "api_app_id")) {
      case (?#string(a)) { a };
      case _ { return #err("Missing 'api_app_id' in event_callback") };
    };
    let eventId = switch (Json.get(json, "event_id")) {
      case (?#string(e)) { e };
      case _ { return #err("Missing 'event_id' in event_callback") };
    };
    let eventTime = switch (Json.get(json, "event_time")) {
      case (?#number(#int(n))) { Int.abs(n) };
      case (?#number(#float(f))) { Int.abs(Float.toInt(f)) };
      case _ { return #err("Missing 'event_time' in event_callback") };
    };

    // Parse inner event
    let eventJson = switch (Json.get(json, "event")) {
      case (?obj) { obj };
      case _ { return #err("Missing 'event' object in event_callback") };
    };

    let innerEvent = switch (parseInnerEvent(eventJson)) {
      case (#ok(e)) { e };
      case (#err(msg)) { return #err(msg) };
    };

    #ok({
      token;
      team_id = teamId;
      api_app_id = apiAppId;
      event = innerEvent;
      event_id = eventId;
      event_time = eventTime;
    });
  };

  /// Parse the inner event object within an event_callback
  func parseInnerEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackInnerEvent;
    #err : Text;
  } {
    let eventType = switch (Json.get(json, "type")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'type' in inner event") };
    };

    switch (eventType) {
      case ("app_mention") {
        switch (parseAppMentionEvent(json)) {
          case (#ok(e)) { #ok(#app_mention(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case ("message") {
        switch (parseMessageEvent(json)) {
          case (#ok(e)) { #ok(#message(e)) };
          case (#err(msg)) { #err(msg) };
        };
      };
      case (other) {
        Logger.log(#warn, ?"SlackAdapter", "Unknown inner event type: " # other);
        #ok(#unknown({ eventType = other }));
      };
    };
  };

  /// Parse app_mention event
  func parseAppMentionEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackAppMentionEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { u };
      case _ { return #err("Missing 'user' in app_mention event") };
    };
    let text = switch (Json.get(json, "text")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'text' in app_mention event") };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in app_mention event") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in app_mention event") };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { t };
      case _ { "" };
    };
    let threadTs = switch (Json.get(json, "thread_ts")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };

    #ok({ user; text; ts; channel; event_ts = eventTs; thread_ts = threadTs });
  };

  /// Parse message event
  func parseMessageEvent(json : Json.Json) : {
    #ok : SlackEventTypes.SlackMessageEvent;
    #err : Text;
  } {
    let user = switch (Json.get(json, "user")) {
      case (?#string(u)) { ?u };
      case _ { null };
    };
    let text = switch (Json.get(json, "text")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };
    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in message event") };
    };
    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in message event") };
    };
    let eventTs = switch (Json.get(json, "event_ts")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };
    let threadTs = switch (Json.get(json, "thread_ts")) {
      case (?#string(t)) { ?t };
      case _ { null };
    };
    let subtype = switch (Json.get(json, "subtype")) {
      case (?#string(s)) { ?s };
      case _ { null };
    };
    let botId = switch (Json.get(json, "bot_id")) {
      case (?#string(b)) { ?b };
      case _ { null };
    };

    #ok({
      user;
      text;
      ts;
      channel;
      event_ts = eventTs;
      thread_ts = threadTs;
      subtype;
      bot_id = botId;
    });
  };

  // ============================================
  // Normalization: Slack → Internal Event
  // ============================================

  /// Convert a parsed SlackEventCallback into a normalized Event
  /// Currently hardcodes workspaceId to 0 (will be mapped in the future)
  ///
  /// @param callback - Parsed Slack event callback
  /// @returns Normalized event or error (e.g., unhandled event type, bot message)
  public func normalizeEvent(callback : SlackEventTypes.SlackEventCallback) : {
    #ok : NormalizedEventTypes.Event;
    #err : Text;
  } {
    let payload : NormalizedEventTypes.EventPayload = switch (callback.event) {
      case (#app_mention(mention)) {
        #app_mention({
          user = mention.user;
          text = mention.text;
          channel = mention.channel;
          ts = mention.ts;
          thread_ts = mention.thread_ts;
        });
      };
      case (#message(msg)) {
        // Skip bot messages and messages with subtypes (system messages)
        switch (msg.bot_id) {
          case (?_) {
            return #err("Skipping bot message");
          };
          case (null) {};
        };
        switch (msg.subtype) {
          case (?_) {
            return #err("Skipping message with subtype");
          };
          case (null) {};
        };
        // Skip messages without user or text
        let user = switch (msg.user) {
          case (?u) { u };
          case (null) { return #err("Skipping message without user") };
        };
        let text = switch (msg.text) {
          case (?t) { t };
          case (null) { return #err("Skipping message without text") };
        };

        #message({
          user;
          text;
          channel = msg.channel;
          ts = msg.ts;
          thread_ts = msg.thread_ts;
        });
      };
      case (#unknown({ eventType })) {
        return #err("Unsupported event type: " # eventType);
      };
    };

    #ok({
      source = #slack;
      workspaceId = 0; // Hardcoded for now — future: map from Slack team_id/channel
      idempotencyKey = callback.event_id;
      timestamp = callback.event_time;
      payload;
    });
  };
};
