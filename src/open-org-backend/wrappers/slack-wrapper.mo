/// Slack Wrapper
/// Handles all outbound communication with the Slack Web API.
///
/// Every function in this module maps to a single Slack API method.
/// Callers supply a decrypted bot token — this module never touches the
/// secrets store or key derivation; that responsibility belongs to the caller.
///
/// Security note: all requests are sent over HTTPS via HttpWrapper, so the
/// Authorization header and request body are encrypted end-to-end and visible
/// only to Slack's servers.

import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Json "mo:json";
import { str; obj } "mo:json";
import HttpWrapper "./http-wrapper";
import JsonSanitizer "../utilities/json-sanitizer";
import UrlEncoding "../utilities/url-encoding";

module {

  // ============================================
  // Constants
  // ============================================

  let SLACK_API_BASE_URL : Text = "https://slack.com/api";

  // ============================================
  // Types
  // ============================================

  /// Successful result from chat.postMessage
  public type PostMessageOk = {
    ts : Text; // Timestamp of the posted message (unique per channel)
    channel : Text; // Channel ID the message was posted to
  };

  // ============================================
  // chat.postMessage
  // ============================================

  /// Post a message to a Slack channel, DM, or private group.
  ///
  /// The `channel` value is passed through unchanged. Slack accepts:
  ///   - Public channel IDs:     C...
  ///   - Private channel IDs:    C... (same format, bot must be a member)
  ///   - MPIM (group DM) IDs:    G...
  ///   - Direct message IDs:     D...
  ///
  /// Threading behaviour:
  ///   - `threadTs = null`   → top-level message (or starts a new thread when
  ///                           the caller passes msg.ts as a subsequent reply)
  ///   - `threadTs = ?ts`    → reply inside an existing thread
  ///
  /// @param token     Decrypted Slack bot token (xoxb-...)
  /// @param channel   Channel/DM/group ID to post to
  /// @param text      Message text (plain text or mrkdwn)
  /// @param threadTs  Optional: ts of the parent message to reply within a thread
  /// @returns #ok with the posted message ts + channel, or #err with a description
  public func postMessage(
    token : Text,
    channel : Text,
    text : Text,
    threadTs : ?Text,
  ) : async {
    #ok : PostMessageOk;
    #err : Text;
  } {
    // Build JSON body — include thread_ts only when provided
    let bodyJson : Json.Json = switch (threadTs) {
      case (null) {
        obj([
          ("channel", str(channel)),
          ("text", str(text)),
        ]);
      };
      case (?ts) {
        obj([
          ("channel", str(channel)),
          ("text", str(text)),
          ("thread_ts", str(ts)),
        ]);
      };
    };

    let requestBody = Json.stringify(bodyJson, null);
    let url = SLACK_API_BASE_URL # "/chat.postMessage";

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # token },
      { name = "Content-Type"; value = "application/json" },
    ];

    let httpResult = await HttpWrapper.post(url, headers, requestBody);

    switch (httpResult) {
      case (#err(e)) {
        #err("HTTP request failed: " # e);
      };
      case (#ok((status, responseBody))) {
        if (status != 200) {
          return #err("chat.postMessage returned HTTP " # debug_show status # ": " # responseBody);
        };
        // Slack always responds with HTTP 200; the real success/failure is in ok/error fields
        parsePostMessageResponse(responseBody);
      };
    };
  };

  // ============================================
  // Response Parsing
  // ============================================

  /// Parse the JSON response from chat.postMessage.
  ///
  /// Success:  { "ok": true,  "ts": "...", "channel": "..." }
  /// Failure:  { "ok": false, "error": "channel_not_found" }
  private func parsePostMessageResponse(responseBody : Text) : {
    #ok : PostMessageOk;
    #err : Text;
  } {
    let json = switch (Json.parse(responseBody)) {
      case (#err(_)) {
        return #err("Failed to parse Slack response as JSON: " # responseBody);
      };
      case (#ok(j)) { j };
    };

    // Check ok field
    let ok = switch (Json.get(json, "ok")) {
      case (?#bool(b)) { b };
      case _ { return #err("Missing or invalid 'ok' field in Slack response") };
    };

    if (not ok) {
      let errorMsg = switch (Json.get(json, "error")) {
        case (?#string(e)) { e };
        case _ { "unknown_error" };
      };
      return #err("Slack API error: " # errorMsg);
    };

    let ts = switch (Json.get(json, "ts")) {
      case (?#string(t)) { t };
      case _ { return #err("Missing 'ts' in Slack response") };
    };

    let channel = switch (Json.get(json, "channel")) {
      case (?#string(c)) { c };
      case _ { return #err("Missing 'channel' in Slack response") };
    };

    #ok({ ts; channel });
  };

  // ============================================
  // Types — Slack Users and Channels
  // ============================================

  /// A Slack workspace member, derived from users.list.
  public type SlackUser = {
    id : Text; // Slack user ID (e.g. U0ADJJQMW4T)
    name : Text; // Username / display name
    isAdmin : Bool; // True if user is a workspace admin
    isOwner : Bool; // True if user is a workspace owner
    isPrimaryOwner : Bool; // True if user is the primary owner
  };

  /// A Slack channel/conversation, derived from conversations.list.
  public type SlackChannel = {
    id : Text; // Channel ID (e.g. CXXXXXXXX)
    name : Text; // Channel name (without #)
  };

  // ============================================
  // Private — Slack API: users.list
  // ============================================

  private type UsersListPage = {
    users : [SlackUser];
    nextCursor : ?Text;
  };

  /// Calls Slack's users.list method and returns one page of results.
  ///
  /// @param token   Decrypted Slack bot token (xoxb-...)
  /// @param cursor  Pagination cursor from a previous response; null for first page
  /// @param limit   Max users per page; null uses Slack's API default
  private func usersList(
    token : Text,
    cursor : ?Text,
    limit : ?Nat,
  ) : async {
    #ok : UsersListPage;
    #err : Text;
  } {
    var url = SLACK_API_BASE_URL # "/users.list";
    var sep = "?";

    switch (limit) {
      case (?l) {
        url #= sep # "limit=" # Nat.toText(l);
        sep := "&";
      };
      case (null) {};
    };

    switch (cursor) {
      case (?c) {
        url #= sep # "cursor=" # UrlEncoding.encodeQueryValue(c);
      };
      case (null) {};
    };

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # token },
    ];

    let httpResult = await HttpWrapper.get(url, headers);

    switch (httpResult) {
      case (#err(e)) { #err("HTTP request failed: " # e) };
      case (#ok((status, responseBody))) {
        if (status != 200) {
          return #err("users.list returned HTTP " # debug_show status # ": " # responseBody);
        };
        parseUsersListPage(responseBody);
      };
    };
  };

  private func parseUsersListPage(responseBody : Text) : {
    #ok : UsersListPage;
    #err : Text;
  } {
    let json = switch (Json.parse(responseBody)) {
      case (#err(_)) {
        return #err("Failed to parse users.list response as JSON: " # responseBody);
      };
      case (#ok(j)) { j };
    };

    let ok = switch (Json.get(json, "ok")) {
      case (?#bool(b)) { b };
      case _ {
        return #err("Missing or invalid 'ok' field in users.list response");
      };
    };

    if (not ok) {
      let errorMsg = switch (Json.get(json, "error")) {
        case (?#string(e)) { e };
        case _ { "unknown_error" };
      };
      return #err("Slack API error: " # errorMsg);
    };

    let membersJson = switch (Json.get(json, "members")) {
      case (?#array(arr)) { arr };
      case _ {
        return #err("Missing or invalid 'members' array in users.list response");
      };
    };

    let users : [SlackUser] = Array.filterMap<Json.Json, SlackUser>(
      membersJson,
      func(memberJson : Json.Json) : ?SlackUser {
        let id = switch (Json.get(memberJson, "id")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        let name = switch (Json.get(memberJson, "name")) {
          case (?#string(s)) { s };
          case _ { "" };
        };
        let isAdmin = switch (Json.get(memberJson, "is_admin")) {
          case (?#bool(b)) { b };
          case _ { false };
        };
        let isOwner = switch (Json.get(memberJson, "is_owner")) {
          case (?#bool(b)) { b };
          case _ { false };
        };
        let isPrimaryOwner = switch (Json.get(memberJson, "is_primary_owner")) {
          case (?#bool(b)) { b };
          case _ { false };
        };
        ?{ id; name; isAdmin; isOwner; isPrimaryOwner };
      },
    );

    let nextCursor = switch (Json.get(json, "response_metadata")) {
      case (?metadata) {
        switch (Json.get(metadata, "next_cursor")) {
          case (?#string(c)) { if (c == "") { null } else { ?c } };
          case _ { null };
        };
      };
      case (null) { null };
    };

    #ok({ users; nextCursor });
  };

  // ============================================
  // Private — Slack API: conversations.list
  // ============================================

  private type ConversationsListPage = {
    channels : [SlackChannel];
    nextCursor : ?Text;
  };

  /// Calls Slack's conversations.list method and returns one page of results.
  ///
  /// @param token   Decrypted Slack bot token (xoxb-...)
  /// @param cursor  Pagination cursor from a previous response; null for first page
  /// @param limit   Max channels per page; null uses Slack's API default
  /// @param types   Comma-separated channel types (e.g. "public_channel,private_channel")
  private func conversationsList(
    token : Text,
    cursor : ?Text,
    limit : ?Nat,
    types : ?Text,
  ) : async {
    #ok : ConversationsListPage;
    #err : Text;
  } {
    var url = SLACK_API_BASE_URL # "/conversations.list";
    var sep = "?";

    switch (limit) {
      case (?l) {
        url #= sep # "limit=" # Nat.toText(l);
        sep := "&";
      };
      case (null) {};
    };

    switch (types) {
      case (?t) {
        url #= sep # "types=" # t;
        sep := "&";
      };
      case (null) {};
    };

    switch (cursor) {
      case (?c) {
        url #= sep # "cursor=" # UrlEncoding.encodeQueryValue(c);
      };
      case (null) {};
    };

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # token },
    ];

    let httpResult = await HttpWrapper.get(url, headers);

    switch (httpResult) {
      case (#err(e)) { #err("HTTP request failed: " # e) };
      case (#ok((status, responseBody))) {
        if (status != 200) {
          return #err("conversations.list returned HTTP " # debug_show status # ": " # responseBody);
        };
        parseConversationsListPage(responseBody);
      };
    };
  };

  private func parseConversationsListPage(responseBody : Text) : {
    #ok : ConversationsListPage;
    #err : Text;
  } {
    let json = switch (Json.parse(JsonSanitizer.sanitizeJsonSurrogates(responseBody))) {
      case (#err(_)) {
        return #err("Failed to parse conversations.list response as JSON: " # responseBody);
      };
      case (#ok(j)) { j };
    };

    let ok = switch (Json.get(json, "ok")) {
      case (?#bool(b)) { b };
      case _ {
        return #err("Missing or invalid 'ok' field in conversations.list response");
      };
    };

    if (not ok) {
      let errorMsg = switch (Json.get(json, "error")) {
        case (?#string(e)) { e };
        case _ { "unknown_error" };
      };
      return #err("Slack API error: " # errorMsg);
    };

    let channelsJson = switch (Json.get(json, "channels")) {
      case (?#array(arr)) { arr };
      case _ {
        return #err("Missing or invalid 'channels' array in conversations.list response");
      };
    };

    let channels : [SlackChannel] = Array.filterMap<Json.Json, SlackChannel>(
      channelsJson,
      func(channelJson : Json.Json) : ?SlackChannel {
        let id = switch (Json.get(channelJson, "id")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        let name = switch (Json.get(channelJson, "name")) {
          case (?#string(s)) { s };
          case _ { "" };
        };
        ?{ id; name };
      },
    );

    let nextCursor = switch (Json.get(json, "response_metadata")) {
      case (?metadata) {
        switch (Json.get(metadata, "next_cursor")) {
          case (?#string(c)) { if (c == "") { null } else { ?c } };
          case _ { null };
        };
      };
      case (null) { null };
    };

    #ok({ channels; nextCursor });
  };

  // ============================================
  // Private — Slack API: conversations.members
  // ============================================

  private type ConversationsMembersPage = {
    members : [Text];
    nextCursor : ?Text;
  };

  /// Calls Slack's conversations.members method and returns one page of user IDs.
  ///
  /// @param token    Decrypted Slack bot token (xoxb-...)
  /// @param channel  Channel ID to fetch members for
  /// @param cursor   Pagination cursor from a previous response; null for first page
  /// @param limit    Max members per page; null uses Slack's API default
  private func conversationsMembers(
    token : Text,
    channel : Text,
    cursor : ?Text,
    limit : ?Nat,
  ) : async {
    #ok : ConversationsMembersPage;
    #err : Text;
  } {
    var url = SLACK_API_BASE_URL # "/conversations.members?channel=" # channel;

    switch (limit) {
      case (?l) { url #= "&limit=" # Nat.toText(l) };
      case (null) {};
    };

    switch (cursor) {
      case (?c) { url #= "&cursor=" # UrlEncoding.encodeQueryValue(c) };
      case (null) {};
    };

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # token },
    ];

    let httpResult = await HttpWrapper.get(url, headers);

    switch (httpResult) {
      case (#err(e)) { #err("HTTP request failed: " # e) };
      case (#ok((status, responseBody))) {
        if (status != 200) {
          return #err("conversations.members returned HTTP " # debug_show status # ": " # responseBody);
        };
        parseConversationsMembersPage(responseBody);
      };
    };
  };

  private func parseConversationsMembersPage(responseBody : Text) : {
    #ok : ConversationsMembersPage;
    #err : Text;
  } {
    let json = switch (Json.parse(responseBody)) {
      case (#err(_)) {
        return #err("Failed to parse conversations.members response as JSON: " # responseBody);
      };
      case (#ok(j)) { j };
    };

    let ok = switch (Json.get(json, "ok")) {
      case (?#bool(b)) { b };
      case _ {
        return #err("Missing or invalid 'ok' field in conversations.members response");
      };
    };

    if (not ok) {
      let errorMsg = switch (Json.get(json, "error")) {
        case (?#string(e)) { e };
        case _ { "unknown_error" };
      };
      return #err("Slack API error: " # errorMsg);
    };

    let membersJson = switch (Json.get(json, "members")) {
      case (?#array(arr)) { arr };
      case _ {
        return #err("Missing or invalid 'members' array in conversations.members response");
      };
    };

    let members : [Text] = Array.filterMap<Json.Json, Text>(
      membersJson,
      func(item : Json.Json) : ?Text {
        switch (item) {
          case (#string(s)) { ?s };
          case _ { null };
        };
      },
    );

    let nextCursor = switch (Json.get(json, "response_metadata")) {
      case (?metadata) {
        switch (Json.get(metadata, "next_cursor")) {
          case (?#string(c)) { if (c == "") { null } else { ?c } };
          case _ { null };
        };
      };
      case (null) { null };
    };

    #ok({ members; nextCursor });
  };

  // ============================================
  // Public — Higher-level Slack operations
  // ============================================

  /// Fetch all organization members, paginating through users.list automatically.
  ///
  /// @param token  Decrypted Slack bot token (xoxb-...)
  /// @returns #ok with the full list of organization users, or #err with a description
  public func getOrganizationMembers(token : Text) : async {
    #ok : [SlackUser];
    #err : Text;
  } {
    var allUsers : [SlackUser] = [];
    var cursor : ?Text = null;
    var keepGoing = true;

    while (keepGoing) {
      let result = await usersList(token, cursor, ?200);
      switch (result) {
        case (#err(e)) { return #err(e) };
        case (#ok(page)) {
          allUsers := Array.concat(allUsers, page.users);
          switch (page.nextCursor) {
            case (null) { keepGoing := false };
            case (?c) { cursor := ?c };
          };
        };
      };
    };

    #ok(allUsers);
  };

  /// Fetch all channels, paginating through conversations.list automatically.
  ///
  /// @param token  Decrypted Slack bot token (xoxb-...)
  /// @param types  Optional comma-separated channel types (e.g. "public_channel,private_channel").
  ///               Pass null to use Slack's default (public_channel only).
  /// @returns #ok with the full list of channels, or #err with a description
  public func listChannels(token : Text, types : ?Text) : async {
    #ok : [SlackChannel];
    #err : Text;
  } {
    var allChannels : [SlackChannel] = [];
    var cursor : ?Text = null;
    var keepGoing = true;

    while (keepGoing) {
      let result = await conversationsList(token, cursor, ?200, types);
      switch (result) {
        case (#err(e)) { return #err(e) };
        case (#ok(page)) {
          allChannels := Array.concat(allChannels, page.channels);
          switch (page.nextCursor) {
            case (null) { keepGoing := false };
            case (?c) { cursor := ?c };
          };
        };
      };
    };

    #ok(allChannels);
  };

  /// Fetch all members of a Slack channel, paginating through conversations.members automatically.
  ///
  /// @param token    Decrypted Slack bot token (xoxb-...)
  /// @param channel  Channel ID to fetch members for (e.g. C012AB3CD)
  /// @returns #ok with the full list of Slack user IDs, or #err with a description
  public func getChannelMembers(token : Text, channel : Text) : async {
    #ok : [Text];
    #err : Text;
  } {
    var allMembers : [Text] = [];
    var cursor : ?Text = null;
    var keepGoing = true;

    while (keepGoing) {
      let result = await conversationsMembers(token, channel, cursor, ?200);
      switch (result) {
        case (#err(e)) { return #err(e) };
        case (#ok(page)) {
          allMembers := Array.concat(allMembers, page.members);
          switch (page.nextCursor) {
            case (null) { keepGoing := false };
            case (?c) { cursor := ?c };
          };
        };
      };
    };

    #ok(allMembers);
  };
};
