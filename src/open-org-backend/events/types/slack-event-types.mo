/// Slack Event Types
/// Raw types that closely mirror what Slack sends
///
/// These types are used by the Slack adapter to parse incoming webhooks.
/// They maintain fidelity to Slack's API schema so we can reliably deserialize
/// their payloads.

module {

  // ============================================
  // Raw Slack Types (mirror Slack's JSON schema)
  // ============================================

  /// Slack event callback envelope (wraps inner event)
  /// See: https://docs.slack.dev/apis/events-api/#callback-field
  public type SlackEventCallback = {
    token : Text; // Deprecated verification token (not used for auth)
    team_id : Text;
    api_app_id : Text;
    event : SlackInnerEvent;
    event_id : Text; // Unique ID for deduplication (e.g., "Ev123ABC456")
    event_time : Nat; // Unix timestamp of the event
  };

  /// Inner event payload from Slack
  /// Each variant corresponds to a Slack event type we handle
  public type SlackInnerEvent = {
    #app_mention : SlackAppMentionEvent;
    #message : SlackMessageEvent;
    #unknown : { eventType : Text }; // Catch-all for unrecognized event types
  };

  /// Slack app_mention event fields
  /// See: https://docs.slack.dev/reference/events/app_mention/
  public type SlackAppMentionEvent = {
    user : Text; // User ID who mentioned the app (e.g., "U061F7AUR")
    text : Text; // Full message text including the mention
    ts : Text; // Message timestamp (unique per channel)
    channel : Text; // Channel ID where the mention occurred
    event_ts : Text; // Event timestamp
    thread_ts : ?Text; // Thread timestamp if the mention is in a thread
  };

  /// Slack message event fields
  /// See: https://docs.slack.dev/reference/events/message/
  public type SlackMessageEvent = {
    user : ?Text; // User ID (null for bot messages / subtypes)
    text : ?Text; // Message text (null for some subtypes)
    ts : Text; // Message timestamp
    channel : Text; // Channel ID
    event_ts : ?Text; // Event timestamp
    thread_ts : ?Text; // Thread timestamp (present if message is in a thread)
    subtype : ?Text; // Message subtype (e.g., "channel_join", "bot_message")
    bot_id : ?Text; // Bot ID if sent by a bot
  };

  /// Slack URL verification challenge
  /// Sent when you first configure the Events API URL
  public type SlackUrlVerification = {
    challenge : Text;
    token : Text;
  };

  /// Slack app rate limited event
  /// Sent when the app is being rate-limited by Slack
  /// See: https://docs.slack.dev/apis/events-api/#rate-limiting
  public type SlackAppRateLimitedEvent = {
    team_id : Text; // Workspace ID that is being rate-limited
    minute_rate_limited : Nat; // Epoch timestamp (rounded to minute) when rate-limiting started
  };

  /// Top-level Slack envelope type (what arrives at http_request_update)
  public type SlackEnvelope = {
    #url_verification : SlackUrlVerification;
    #event_callback : SlackEventCallback;
    #app_rate_limited : SlackAppRateLimitedEvent;
    #unknown : Text; // Unrecognized envelope type
  };
};
