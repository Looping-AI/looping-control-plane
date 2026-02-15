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

  /// Slack message event — variant by subtype
  /// The message event is polymorphic: the fields change based on the subtype.
  /// See: https://docs.slack.dev/reference/events/message/#subtypes
  public type SlackMessageEvent = {
    #standard : SlackStandardMessage;
    #botMessage : SlackBotMessage;
    #meMessage : SlackMeMessage;
    #threadBroadcast : SlackThreadBroadcastMessage;
    #assistantAppThread : SlackAssistantAppThreadMessage;
    #messageChanged : SlackMessageChangedEvent;
    #messageDeleted : SlackMessageDeletedEvent;
    #other : { subtype : Text; channel : Text; ts : Text };
  };

  /// Standard user message (no subtype)
  /// See: https://docs.slack.dev/reference/events/message/
  public type SlackStandardMessage = {
    user : Text;
    text : Text;
    ts : Text;
    channel : Text;
    eventTs : Text;
    threadTs : ?Text;
  };

  /// Bot message (subtype: "bot_message")
  /// See: https://docs.slack.dev/reference/events/message/bot_message
  public type SlackBotMessage = {
    botId : Text;
    text : Text;
    ts : Text;
    channel : Text;
    username : ?Text;
  };

  /// /me message (subtype: "me_message")
  /// See: https://docs.slack.dev/reference/events/message/me_message
  public type SlackMeMessage = {
    user : Text;
    text : Text;
    ts : Text;
    channel : Text;
  };

  /// Thread reply broadcast to channel (subtype: "thread_broadcast")
  /// See: https://docs.slack.dev/reference/events/message/thread_broadcast
  public type SlackThreadBroadcastMessage = {
    user : Text;
    text : Text;
    ts : Text;
    channel : Text;
    threadTs : Text;
    eventTs : Text;
  };

  /// Assistant app thread root message (subtype: "assistant_app_thread")
  /// Arrives wrapped inside a message_changed event.
  /// See: https://docs.slack.dev/reference/events/message/assistant_app_thread
  public type SlackAssistantAppThreadMessage = {
    user : Text;
    text : Text;
    ts : Text;
    channel : Text;
    threadTs : Text;
    title : ?Text; // From assistant_app_thread.title
  };

  /// Message changed (subtype: "message_changed", hidden: true)
  /// See: https://docs.slack.dev/reference/events/message/message_changed
  public type SlackMessageChangedEvent = {
    channel : Text;
    ts : Text; // Event timestamp
    message : SlackChangedMessagePayload;
  };

  /// Inner message payload within a message_changed event
  public type SlackChangedMessagePayload = {
    user : Text;
    text : Text;
    ts : Text; // Original message timestamp (use for matching)
    edited : ?{ user : Text; ts : Text };
  };

  /// Message deleted (subtype: "message_deleted", hidden: true)
  /// See: https://docs.slack.dev/reference/events/message/message_deleted
  public type SlackMessageDeletedEvent = {
    channel : Text;
    ts : Text; // Event timestamp
    deletedTs : Text; // Timestamp of the deleted message
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
