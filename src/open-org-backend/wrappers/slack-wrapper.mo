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
import Json "mo:json";
import { str; obj } "mo:json";
import HttpWrapper "./http-wrapper";

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
};
