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
    #assistant_thread_started : SlackAssistantThreadStartedEvent;
    #assistant_thread_context_changed : SlackAssistantThreadContextChangedEvent;
    #member_joined_channel : SlackMemberJoinedChannelEvent;
    #member_left_channel : SlackMemberLeftChannelEvent;
    #team_join : SlackTeamJoinEvent;
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
    #meMessage : SlackMeMessage;
    #assistantAppThread : SlackAssistantAppThreadMessage;
    #messageChanged : SlackMessageChangedEvent;
    #messageDeleted : SlackMessageDeletedEvent;
    /// Known subtype we have explicitly decided to skip (e.g. bot_message, thread_broadcast).
    /// Distinct from #other, which is for subtypes not yet encountered or decided.
    #skip : { subtype : Text };
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
    botId : ?Text; // Present when the message was posted by a bot
    appId : ?Text; // Slack app ID of the sender (matches api_app_id for own-bot messages)
  };

  /// /me message (subtype: "me_message")
  /// See: https://docs.slack.dev/reference/events/message/me_message
  public type SlackMeMessage = {
    user : Text;
    text : Text;
    ts : Text;
    channel : Text;
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
    threadTs : ?Text; // Present when the message is part of a thread
    edited : ?{ user : Text; ts : Text };
  };

  /// Message deleted (subtype: "message_deleted", hidden: true)
  /// See: https://docs.slack.dev/reference/events/message/message_deleted
  public type SlackMessageDeletedEvent = {
    channel : Text;
    ts : Text; // Event timestamp
    deletedTs : Text; // Timestamp of the deleted message
  };

  /// assistant_thread_started event — fired when a user opens an assistant thread
  /// See: https://docs.slack.dev/reference/events/assistant_thread_started
  public type SlackAssistantThreadStartedEvent = {
    assistant_thread : {
      user_id : Text; // Slack user ID who opened the thread
      context : {
        force_search : Bool; // Whether Slack is hinting the AI should favour search results
      };
      channel_id : Text; // The DM channel hosting the assistant thread
      thread_ts : Text; // Timestamp that identifies the thread
    };
    event_ts : Text;
  };

  /// assistant_thread_context_changed event — fired when the user navigates to a different
  /// channel or conversation while the assistant thread is open, giving the AI new context.
  /// See: https://docs.slack.dev/reference/events/assistant_thread_context_changed
  public type SlackAssistantThreadContextChangedEvent = {
    assistant_thread : {
      user_id : Text; // Slack user ID whose context changed
      context : {
        channel_id : ?Text; // Channel the user is now viewing
        team_id : ?Text; // Workspace of that channel
        enterprise_id : ?Text; // Enterprise Grid org (null for standard workspaces)
      };
      channel_id : Text; // The DM channel hosting the assistant thread
      thread_ts : Text; // Timestamp that identifies the thread
    };
    event_ts : Text;
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

  /// member_joined_channel event — fired when a user joins a channel
  /// See: https://api.slack.com/events/member_joined_channel
  public type SlackMemberJoinedChannelEvent = {
    user : Text; // Slack user ID of the member who joined
    channel : Text; // Channel ID
    channel_type : Text; // e.g. "C" for public channel
    team : Text; // Workspace team ID
    event_ts : Text;
  };

  /// member_left_channel event — fired when a user leaves a channel
  /// See: https://api.slack.com/events/member_left_channel
  public type SlackMemberLeftChannelEvent = {
    user : Text; // Slack user ID of the member who left
    channel : Text; // Channel ID
    channel_type : Text; // e.g. "C" for public channel
    team : Text; // Workspace team ID
    event_ts : Text;
  };

  /// Minimal user object nested inside team_join event
  public type SlackTeamJoinUser = {
    id : Text; // Slack user ID
    name : Text; // Username / handle
    real_name : ?Text; // Display name (may be absent)
    is_primary_owner : Bool;
    is_admin : Bool;
  };

  /// team_join event — fired when a new user joins the Slack workspace
  /// See: https://api.slack.com/events/team_join
  public type SlackTeamJoinEvent = {
    user : SlackTeamJoinUser;
    event_ts : Text;
  };
};
