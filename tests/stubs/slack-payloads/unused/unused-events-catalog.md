# Unused Slack Event Stubs Catalog

This catalog contains Slack event payload stubs that are **not currently in use** by the test suite. These are available for reference and future testing scenarios.

## How to Use These Stubs

### 1. **Find Your Event Type**

Browse through the sections below to find the Slack event type you need:

- [App Mention](#app-mention)
- [App Rate Limited](#app-rate-limited)
- [Bot Message](#bot-message)
- [Channel Join](#channel-join)
- [Message Changed - Assistant App Thread](#message-changed-assistant-app-thread)
- [Me Message](#me-message)
- [URL Verification](#url-verification)

### 2. **Copy the Payload**

Copy the JSON payload from the code block under your event type.

### 3. **Create a New Stub File** (if integrating into active tests)

- Create a new `.json` file in `/tests/stubs/slack-payloads/`
- Name it descriptively (e.g., `app-mention.json`)
- Paste the copied payload

### 4. **Update the Payload**

Replace placeholder values with real data from Slack logs:

- `""` (empty strings) - fill with actual tokens, IDs, and timestamps
- `0` (numeric zeros) - fill with actual numeric values like timestamps

### 5. **Use in Tests**

```typescript
import eventStub from "../../../stubs/slack-payloads/app-mention.json";

describe("My Test", () => {
  it("handles app mention events", () => {
    // Use eventStub in your test
  });
});
```

## Integration Notes

- These stubs are in JSON format to allow for easy copy-pasting while they're not actively used
- If you need to activate any of these for testing, move the created `.json` file to the main `slack-payloads/` directory
- Update imports in test files to reference the new location
- Always replace placeholder values with real data when testing

---

## Event Stubs

### App Mention

**Trigger Method**: @mention your bot in a channel  
**Use Case**: Testing bot mentions and @mentions in channels

#### Payload

```json
{
  "TODO": "Paste a real app_mention event_callback payload from Slack logs here. Trigger by @mentioning your bot in a channel.",
  "type": "event_callback",
  "token": "YOUR_TOKEN",
  "team_id": "T00000000",
  "api_app_id": "A00000000",
  "event": {
    "type": "app_mention",
    "user": "U00000001",
    "text": "<@U12345678> hello bot",
    "ts": "1234567890.123456",
    "channel": "C00000001",
    "event_ts": "1234567890.123456"
  },
  "event_id": "Ev00000001",
  "event_time": 1234567890
}
```

---

### App Rate Limited

**Trigger Method**: Hard to trigger intentionally — may require simulating high event volume  
**Use Case**: Testing rate limiting behavior and throttling logic

#### Payload

```json
{
  "TODO": "Paste a real app_rate_limited payload from Slack logs here. This is sent when your app is being rate-limited. Hard to trigger intentionally — may need to simulate high event volume.",
  "type": "app_rate_limited",
  "team_id": "T00000000",
  "minute_rate_limited": 1234567890
}
```

---

### Bot Message

> **Note: Legacy event — not received by new Slack apps.**
>
> The `bot_message` subtype belong to Slack's
> legacy bot infrastructure. New apps using the current Events API only receive standard messages with a `bot_id`and `app_id`field, instead of a specific subtype.
>
> Because this app is a new app, `bot_message` events are not expected and we don't need to create logic for handling it.

**Use Case**: N/A — not supported; kept here for documentation purposes

#### Payload

```json
{
  "type": "event_callback",
  "token": "YOUR_TOKEN",
  "team_id": "T00000000",
  "api_app_id": "A00000000",
  "event": {
    "type": "message",
    "subtype": "bot_message",
    "bot_id": "B00000001",
    "app_id": "A00000001",
    "text": "Hello from a third-party bot",
    "ts": "1234567890.123456",
    "channel": "C00000001",
    "username": "third-party-bot"
  },
  "event_id": "Ev00000001",
  "event_time": 1234567890
}
```

---

### Channel Join

**Trigger Method**: User or Bot joins a channel  
**Use Case**: Testing channel join notifications and member activity tracking

#### Payload

```json
{
  "token": "8c7TifzO0tqc8zbNGyQar24F",
  "team_id": "T0ADR0P92G2",
  "context_team_id": "T0ADR0P92G2",
  "context_enterprise_id": null,
  "api_app_id": "A0ADJUKD8TV",
  "event": {
    "type": "message",
    "subtype": "channel_join",
    "user": "U0ADWN7P3DY",
    "text": "<@U0ADWN7P3DY> has joined the channel",
    "inviter": "U0ADJJQMW4T",
    "ts": "1771575931.715389",
    "channel": "C0AFNSE98CX",
    "event_ts": "1771575931.715389",
    "channel_type": "group"
  },
  "type": "event_callback",
  "event_id": "Ev0AG118UT0V",
  "event_time": 1771575931,
  "authorizations": [
    {
      "enterprise_id": null,
      "team_id": "T0ADR0P92G2",
      "user_id": "U0ADWN7P3DY",
      "is_bot": true,
      "is_enterprise_install": false
    }
  ],
  "is_ext_shared_channel": false,
  "event_context": "4-eyJldCI6Im1lc3NhZ2UiLCJ0aWQiOiJUMEFEUjBQOTJHMiIsImFpZCI6IkEwQURKVUtEOFRWIiwiY2lkIjoiQzBBRk5TRTk4Q1gifQ"
}
```

---

### Message Changed - Assistant App Thread

**Trigger Method**: Have an assistant app thread created (Slack's AI assistant feature)  
**Use Case**: Testing message edits involving Slack's AI assistant

#### Payload

```json
{
  "TODO": "Paste a real message_changed with assistant_app_thread event_callback payload from Slack logs here. Trigger by having an assistant app thread created (Slack's AI assistant feature). The inner message will have subtype 'assistant_app_thread'.",
  "type": "event_callback",
  "token": "YOUR_TOKEN",
  "team_id": "T00000000",
  "api_app_id": "A00000000",
  "event": {
    "type": "message",
    "subtype": "message_changed",
    "message": {
      "type": "message",
      "user": "U00000001",
      "text": "Updated assistant message",
      "ts": "1234567890.123456",
      "subtype": "assistant_app_thread"
    },
    "previous_message": {
      "type": "message",
      "user": "U00000001",
      "text": "Original assistant message",
      "ts": "1234567890.123456"
    },
    "channel": "C00000001",
    "hidden": true,
    "event_ts": "1234567891.123456"
  },
  "event_id": "Ev00000001",
  "event_time": 1234567891
}
```

---

### Me Message

**Trigger Method**: Send a `/me` message in a channel (e.g., `/me is testing`)  
**Use Case**: Testing action messages (me_messages)

#### Payload

```json
{
  "TODO": "Paste a real me_message event_callback payload from Slack logs here. Trigger by sending a /me message in a channel (e.g. '/me is testing').",
  "type": "event_callback",
  "token": "YOUR_TOKEN",
  "team_id": "T00000000",
  "api_app_id": "A00000000",
  "event": {
    "type": "message",
    "subtype": "me_message",
    "user": "U00000001",
    "text": "is testing the bot",
    "ts": "1234567890.123456",
    "channel": "C00000001",
    "event_ts": "1234567890.123456"
  },
  "event_id": "Ev00000001",
  "event_time": 1234567890
}
```

---

### URL Verification

**Trigger Method**: Re-configure the Events API URL in your Slack app settings  
**Use Case**: Testing Slack's URL verification challenge response

#### Payload

```json
{
  "TODO": "Paste a real url_verification payload from Slack logs here. Trigger by re-configuring the Events API URL in your Slack app settings.",
  "type": "url_verification",
  "challenge": "3eZbrw1aBrO2OwwZuRckYRpG0E8iBd9qS1234567890",
  "token": "Jhj5dajhtbSuc0DYvJ5d1234567890"
}
```

---
