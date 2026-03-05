# HTTP Cassettes

This directory contains recorded HTTP interactions for integration tests.

## Overview

Cassettes are JSON files that store HTTP request/response pairs. They allow tests to:

- Run **fast** without real network calls
- Run **deterministically** with consistent responses
- Run **offline** in CI environments without API keys

## Directory Structure

```
cassettes/
├── README.md           # This file
├── conversations/      # Cassettes for conversation tests
│   ├── chat-simple.json
│   └── chat-multi-turn.json
├── agents/             # Cassettes for agent tests
│   └── ...
└── api-keys/           # Cassettes for API key tests
    └── ...
```

## Recording Cassettes

To record new cassettes, run tests with the `RECORD_CASSETTES` environment variable:

```bash
# Record all cassettes
RECORD_CASSETTES=true bun test

# Record cassettes for a specific test file
RECORD_CASSETTES=true bun test conversations.spec.ts

# Record cassettes for a specific test
RECORD_CASSETTES=true bun test -t "should chat with agent"
```

**Requirements for recording:**

- Network access to the APIs being called
- Valid API keys in `.env.test` (e.g., `GROQ_TEST_KEY`)

## Playback (Default Mode)

When running tests normally, cassettes are used for playback:

```bash
bun test
```

If a cassette is missing, the test will fail with a helpful error message.

## Cassette File Format

```json
{
  "version": 1,
  "name": "chat-simple",
  "recordedAt": "2026-01-18T10:30:00.000Z",
  "interactions": [
    {
      "request": {
        "url": "https://api.groq.com/openai/v1/chat/completions",
        "method": "POST",
        "headers": [
          ["content-type", "application/json"],
          ["authorization", "[REDACTED]"]
        ],
        "body": "eyJtb2RlbCI6Imxs..." // Base64 encoded
      },
      "response": {
        "statusCode": 200,
        "headers": [["content-type", "application/json"]],
        "body": "eyJpZCI6ImNoYXRj..." // Base64 encoded
      },
      "matchRules": {
        "ignoreBodyFields": ["timestamp", "messages.*.id"]
      }
    }
  ]
}
```

## Match Rules

You can configure flexible matching with `matchRules`:

| Rule                | Description                          | Example                            |
| ------------------- | ------------------------------------ | ---------------------------------- |
| `ignoreHeaders`     | Headers to ignore when matching      | `["x-request-id"]`                 |
| `ignoreBodyFields`  | JSON paths to ignore in request body | `["timestamp", "messages.*.id"]`   |
| `ignoreQueryParams` | Ignore URL query parameters          | `true`                             |
| `urlPattern`        | Regex pattern for URL matching       | `"https://api\\.example\\.com/.*"` |

## Security

Sensitive data is automatically redacted during recording:

- `Authorization` headers → `[REDACTED]`
- `X-API-Key` headers → `[REDACTED]`
- `API-Key` headers → `[REDACTED]`

You can add custom redactions via `RecordOptions`:

```typescript
await HttpCassette.record("my-test", {
  redactHeaders: ["x-custom-secret"],
  redactBodyFields: ["api_key", "credentials.token"],
});
```

## Updating Cassettes

When APIs change, re-record affected cassettes:

```bash
RECORD_CASSETTES=true bun test conversations.spec.ts
```

The system will warn if cassettes are older than 30 days.

## Troubleshooting

### "Cassette not found" error

Run with `RECORD_CASSETTES=true` to create the cassette:

```bash
RECORD_CASSETTES=true bun test your-test.spec.ts
```

### "No cassette match found" error

The recorded request doesn't match the current request. Common causes:

- Request body changed (consider `ignoreBodyFields`)
- URL changed (check the cassette file)
- Different HTTP method

### Stale cassette warning

Re-record the cassette to get fresh API responses:

```bash
RECORD_CASSETTES=true bun test your-test.spec.ts
```

## API Reference

### Basic Usage

```typescript
import { withCassette } from "../lib/test-with-cassette";

it("should chat with agent", async () => {
  const { result } = await withCassette(pic, "conversations/chat-simple", () =>
    deferredActor.talkTo(agentId, "Hello!"),
  );

  expect(result.ok).toBeDefined();
});
```

### Multiple Calls

```typescript
import { withCassetteMulti } from "../lib/test-with-cassette";

it("should have a conversation", async () => {
  const { results } = await withCassetteMulti(pic, "conversations/multi-turn", [
    () => deferredActor.talkTo(agentId, "Hello!"),
    () => deferredActor.talkTo(agentId, "How are you?"),
  ]);

  expect(results).toHaveLength(2);
});
```

### Manual Control

```typescript
import { HttpCassette } from "../lib/http-cassette";

it("custom flow", async () => {
  const cassette = await HttpCassette.auto("my-test");

  // Execute deferred call
  const execute = await deferredActor.someMethod();
  await pic.tick(2);

  // Handle HTTP outcalls
  await cassette.handleOutcalls(pic);

  // Get result
  const result = await execute();

  // Save if recording
  await cassette.save();
});
```

## Best Practices

1. **Name cassettes descriptively**: `conversations/chat-with-context` not `test1`
2. **One cassette per test**: Avoid sharing cassettes between tests
3. **Review recorded cassettes**: Check for accidentally committed secrets
4. **Update regularly**: Re-record monthly or when APIs change
5. **Use match rules sparingly**: Exact matching catches more bugs
