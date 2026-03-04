# PLAN.md — Looping AI Short-Term Planning

This plan describes the incremental path from the current codebase to the architecture described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Instructions

Each Phase is broken down into separate Tasks, each a separate development effort (separate PRs). Phases and Tasks are ordered by dependency, not priority — some later Phases may start in parallel with earlier ones where there are no blockers.

Each Phase is assigned a unique, sequential ID. Once a Phase is fully completed, the Phase at position n-2 can be safely deleted, retaining one prior Phase for context.

Here’s a cleaner, structured version with better flow:

Each Task (using decimal notation, e.g., 0.x, 1.x) should begin in short form. Before implementation, it must be expanded into long form, then executed and marked as complete by striking through its title (e.g., ~~### 0.1 – User Model~~).

Short form consists of a title and supporting bullet points only.

Long form must include at least the following sections:

- Goal
- Current State
- Desired State
- Source Steps
- Test Steps

Then other optional sections can be added that you think are relevant for that specific task.

NOTE: Plans are not documentation. They are temporary and will be discarded. If behavior changes later, there’s no need to update an already struck-through Task.

---

## Phase 1 — Agent Registry & Routing

**Goal**: Introduce the agent registry, `::` syntax, session tracking, and the Agent Router with round control.

~~### 1.1 — Agent registry model~~

- New persistent model: `AgentRegistryState = { nextId, agentsById: Map<Nat, AgentRecord>, agentsByName: Map<Text, Nat> }` — dual index for O(1) lookup by ID or name.
- `AgentRecord = { id, name, category, llmModel, secretsAllowed: [(workspaceId, SecretId)], toolsAllowed, toolsState, sources }`.
- `toolsState`: per-tool `{ usageCount, knowHow: Text }`.
- CRUD: `register`, `updateById`, `unregisterById`, `lookupById`, `lookupByName`, `listAgents`, `getFirstByCategory`.

~~### 1.2 — `::` reference syntax parser~~

- Parse messages for `::agentname` references.
- Regex: `(?<!\\)(?<!\w)::([a-z][a-z0-9-]*)`.
- Ignore inline code, code blocks, escaped `\::agent`.
- Validate against agent registry (case-insensitive).
- Extract referenced agent(s) from a message payload.

~~### 1.3 — UserAuthContext round tracking~~

- Add `roundCount` and `forceTerminated` to `UserAuthContext`.
- When a new event arrives from a bot message: look up parent session → inherit `userAuthContext` → increment `roundCount`.
- **Pre-conditions (checked before routing):**
  - `forceTerminated: true` on inherited context → discard/skip event, close session.
  - No valid `::agentname` reference found in the message (i.e., no name matches the agent registry) → discard/skip event.

~~### 1.4 — Refactor Conversations Model~~

**Goal:** Replace the workspace+agent-keyed conversation store with a channel-keyed, group-structured persistent store with 1-month ts-based retention.

**Why this is needed before 1.5+:** The Agent Router (1.5) and session tracking (1.7) need to resolve conversation context from a `channelId + rootTs` pair derived directly from an incoming Slack event. The current `(workspaceId, agentId)` key has no direct mapping to a Slack event payload, making routing fragile.

#### Problems with the current model

- Keyed by `(workspaceId, agentId)` — arbitrary internal IDs not derivable from a Slack event.
- `adminConversations` is a separate parallel structure with a different key, duplicating logic.
- No `ts` field — messages cannot be correlated back to Slack events or deduplicated.
- No retention policy — unbounded growth.
- `author` enum mixes persistent identity (`#user`) with ephemeral LLM artifacts (`#tool_call`, `#tool_response`), coupling the store to LLM protocol details.

#### Core types

**`ConversationMessage`** — App-internal, does not mirror Slack's field names:

```motoko
{
  ts : Text; // Slack ts — unique per channel; dedup key
  userAuthContext : ?UserAuthContext; // null on arrival; populated during event processing
  text : Text; // current text; replaced in-place on message_changed
};

```

`userAuthContext` starts as `null` so messages can be stored immediately on receipt, before authentication is resolved.

**`ThreadGroup`** — a thread that has a root message and one or more replies:

```motoko
{
  rootTs : Text; // ts of the thread root message
  messages : Map<Text, ConversationMessage>; // messages keyed by ts, sorted chronologically via Text.compare
};

```

**`TimelineEntry`** — a single entry in the channel timeline (union type):

```motoko
{
  #post : ConversationMessage; // standalone top-level message (no replies yet)
  #thread : ThreadGroup; // promoted after first reply arrives
};

```

**`ChannelStore`** — per-channel index structures:

```motoko
{
  timeline : Map<Text, TimelineEntry>; // full ordered timeline; O(log N) lookup by ts
  replyIndex : Map<Text, Text>; // reply ts → root ts; sparse index for fast root lookup
};

```

#### Store structure

The conversation store is channel-keyed with dual indexing per channel:

```motoko
ConversationStore = Map<Text, ChannelStore>

```

- Outer key: Slack channel ID (`Text`) — O(1) channel lookup.
- Per-channel value: `ChannelStore` containing:
  - `timeline`: Map from timestamp (root or post ts) to `TimelineEntry`. O(log N) direct lookup of posts/threads by ts.
  - `replyIndex`: Map from reply ts to root ts. Sparse (only contains replies, never root posts). Enables O(log R) identification of a reply's parent thread when deleting or updating without scanning the timeline.

#### Operations

- `addMessage(store, channelId, msg, threadTs)`:
  - If `threadTs == null`: create a new entry in the timeline as `#post msg` (no replyIndex entry).
  - If `threadTs != null`: add to replyIndex and either:
    - Append to existing `#thread` at `rootTs` (if it already has replies).
    - Promote existing `#post` at `rootTs` to `#thread` (first reply upgrade).
    - Create sparse `#thread` at `rootTs` (reply arrived before root).
  - All maps are updated in-place; mutations persist via reference.
- `getEntry(store, channelId, rootTs)` → `?TimelineEntry` — direct O(log N) lookup of a post or thread by its ts; used by services to build LLM context windows.
- `getRecentEntries(store, channelId, limit)` → `[{ ts: Text, hasReplies: Bool }]` — returns the last `limit` entries from the timeline with lightweight summary. Used to build batch context or answer "show me recent threads and which have new replies". Entries are sorted chronologically (lexicographic on ts).
- `updateMessageText(store, channelId, rootTs, ts, newText)` — replaces `text` on the matching message; O(log N + log M) lookup, no list traversal, in-place update. `rootTs` is derived from the `message_changed` event (`thread_ts ?? ts`).
- `deleteMessage(store, channelId, rootTs, ts)` — removes the message; if the #thread becomes empty, removes the timeline entry too. Cleans up replyIndex entries for any replies to that thread.
- `findAndDeleteMessage(store, channelId, ts)` — finds and removes a message without knowing `rootTs` up-front. Checks replyIndex first (fast for replies), then timeline (for root/post ts). Used by the message_deleted handler.
- `pruneChannel(store, channelId, cutoffSecs)` — drops timeline entries where ALL messages are older than `cutoffSecs`. Applies old-thread grace rule: if any message in a #thread is recent, the entire thread is kept. Old-thread placeholder: replies to pruned threads create sparse entries. O(N × M) full scan; runs at most once per week.
- `pruneAll(store, cutoffSecs)` — iterates all channels and calls `pruneChannel`; invoked by the Sunday cleanup timer.

#### Retention — ts-based cutoff, no `receivedAt`

Slack `ts` strings have the format `"UNIX_SECONDS.MICROSECONDS"` (e.g. `"1740000000.123456"`). The integer prefix is directly comparable to wall-clock seconds.

- New constant: `CONVERSATION_RETENTION_SECS : Nat = 30 * 24 * 3600` — add to `constants.mo`.
- Cutoff computation: `cutoffSecs = (Time.now() / 1_000_000_000) - CONVERSATION_RETENTION_SECS`.
- **Prune condition (with old-thread grace):** parse integer prefix of each message's `ts` in the timeline entry (all messages, not just the root):
  - If **any message** in the entry has `ts >= cutoffSecs` (i.e., is within 1 month old), keep the entire timeline entry.
  - If **all messages** in the entry have `ts < cutoffSecs` (i.e., all older than 1 month), drop the timeline entry.
  - This ensures that a message posted to an old thread within the last month is retained, even if the thread root is older than 1 month.
- **Old-thread placeholder:** when a message arrives with `threadTs` pointing to a timeline entry older than 1 month:
  - Create or append to a sparse `#thread` entry with `rootTs = threadTs` and only store the new message (do not backfill or fetch old stale messages).
  - This treats recent replies to old threads as isolated messages rather than requiring full historical context.
- No extra timestamp field needed — `ts` itself carries the age information.

#### LLM tool messages — ephemeral, not persisted

Tool call and tool response artifacts (`#tool_call`, `#tool_response`) are **not written** to the conversation store. They exist only in-memory during a single service invocation and are discarded when the async call returns.

Please add this comment:

```motoko
// TODO: when Sessions are implemented (Phase 1.7), associate in-flight tool call/response
// history with a SessionRecord rather than keeping it purely ephemeral. Sessions will be
// nextId-based and optionally linkable to a slackTs, a batch of ts values, or future
// concepts like Tasks and Strategies.

```

Services build LLM context by:

1. Calling `getEntry(store, channelId, rootTs)` → `?TimelineEntry` (either `#post` or `#thread` with full message history).
2. Extracting messages from the entry and mapping each `ConversationMessage` to an LLM role via `userAuthContext` (null → #assistant, non-null → #user).
3. Appending ephemeral tool messages (tool call/response) in-memory only during the multi-turn reasoning loop (not persisted to the conversation store).

#### State migration in `main.mo`

- Remove `conversations : Map<ConversationKey, List<Message>>`.
- Remove `adminConversations : Map<Nat, List<Message>>`.
- Remove `ConversationKey` type and `conversationKeyCompare` helper.
- Add `conversationStore : ConversationStore` as the single persistent conversation state.

#### Impact on downstream phases

- **1.5 (Agent Router):** resolves context via `getEntry(store, channelId, rootTs)` or `getRecentEntries(store, channelId, limit)` — no workspace/agent ID lookup needed.
- **1.6 (Generic agent service):** receives a `TimelineEntry` (either `#post` or `#thread` with full message history) instead of a generic list; LLM role is derived from each `ConversationMessage.userAuthContext` without additional lookups.
- **1.7 (Session tracking):** `channelId + ts` (or a batch of `ts` values) becomes the canonical anchor for `SessionRecord`.

~~### 1.5 — Round Refactor with Metadata strategy~~

**Goal**: Decouple round tracking from Slack threading. The current design uses `threadTs` as the round-context key, which breaks for DMs (no thread), cross-channel replies, and any future topology where the bot does not reply inside the originating thread. The metadata strategy moves lineage onto the message itself, making the chain self-describing regardless of channel or thread structure.

#### Problems with the current model

- `roundContexts : Map<rootTs, UserAuthContext>` in `ChannelStore` is keyed to `threadTs` — meaningless for DMs and cross-channel replies.
- The Slack adapter filters own-bot messages by `threadTs != null` — this gate becomes wrong in the same scenarios.
- `saveRoundContext` / `lookupRoundContext` are a parallel identity-store that duplicates what `ConversationMessage.userAuthContext` already carries per message.
- `withRound` produces a free-floating copy with no reference back to the message that triggered it — the chain is implicit and non-traversable.

#### Core design

When the bot posts an agent reply it embeds a `metadata` block in the Slack message (via `chat.postMessage`). When that reply is received back as an event, the metadata is parsed and used to reconstruct the lineage and round count — no separate server-side index needed.

**`AgentMessageMetadata`** — carried on every bot reply:

```motoko
public type AgentMessageMetadata = {
  event_type : Text; // Always "looping_agent_message"
  event_payload : {
    parent_agent : Text; // ::name that triggered this reply (e.g. "::admin")
    parent_ts : Text; // ts of the message this is a reply to
    parent_channel : Text; // channel of that message (ts is channel-scoped; both needed)
  };
};

```

Round count is **not** stored in metadata. It is derived on receipt: look up `parent_ts` in `parent_channel` from the conversation store → read its `userAuthContext.roundCount` → new round = `parent.roundCount + 1`. This is always a single O(log N) lookup since we have the exact key.

**`UserAuthContext`** gains `parentRef`:

```motoko
public type UserAuthContext = {
  slackUserId : Text;
  isPrimaryOwner : Bool;
  isOrgAdmin : Bool;
  workspaceScopes : Map<Nat, WorkspaceScope>;
  roundCount : Nat;
  forceTerminated : Bool;
  parentRef : ?{ channelId : Text; ts : Text }; // null = round 0 (original user message)
};

```

`parentRef = null ↔ roundCount = 0` is an invariant. Following the chain: take `parentRef`, fetch that `ConversationMessage` from the store, read its `userAuthContext`, repeat. The chain terminates when `parentRef == null`.

#### Sub-steps

**1.5.1 — Define `AgentMessageMetadata` type**

- Add to `types.mo` (or a new `src/open-org-backend/events/types/agent-metadata-types.mo`).
- `event_type` is always `"looping_agent_message"`.
- `event_payload` carries `parent_agent`, `parent_ts`, `parent_channel`.

**1.5.2 — Add `parentRef` to `UserAuthContext`**

- Add `parentRef : ?{ channelId : Text; ts : Text }` to the type in `slack-auth-middleware.mo`.
- `buildFromCache` initializes it to `null`.
- `withRound` gains a `parentRef` parameter; callers pass `?{ channelId = triggeringMsg.channel; ts = triggeringMsg.ts }`.
- Update all existing call sites of `withRound`.

**1.5.3 — Update `SlackWrapper.postMessage` to accept metadata**

- Add `metadata : ?AgentMessageMetadata` parameter.
- When present, serialize to the `metadata` JSON field in the `chat.postMessage` body:
  ```json
  { "event_type": "looping_agent_message", "event_payload": { ... } }
  ```
- When absent, omit the field entirely (no change to existing callers that pass `null`).
- Note: `metadata:read` / `metadata:write` OAuth scopes may be required. Test with current scopes first; add scopes to the app manifest if Slack rejects the payload or omits the field on receipt.

**1.5.4 — Parse metadata in the Slack adapter**

- In `parseStandardMessage`, after existing fields, attempt to parse `metadata`:

  ```motoko
  let agentMetadata : ?AgentMessageMetadata = switch (Json.get(json, "metadata")) {
    case (?metaJson) { parseAgentMetadata(metaJson) };
    case _ { null };
  };

  ```

- Add private `parseAgentMetadata` that validates `event_type == "looping_agent_message"` and extracts the three payload fields; returns `null` on any mismatch or missing field.
- `agentMetadata` is added to `SlackStandardMessage` and flows into the normalized `#message` payload.

**1.5.5 — Replace thread-based own-bot filter in the adapter**

Current guard:

```
own-bot + threadTs == null  →  skip
own-bot + threadTs != null  →  allow
```

New guard:

```
own-bot + agentMetadata == null  →  skip (no lineage; can't track)
own-bot + agentMetadata != null  →  allow (metadata IS the lineage)
```

This is the unlock for DMs and cross-channel replies: presence of `agentMetadata` is the sole gate, independent of thread structure.

**1.5.6 — Refactor `MessageHandler` round tracking**

_User message path (unchanged logic):_

- Authenticate → `buildFromCache` → `parentRef = null, roundCount = 0`.
- Store `userAuthContext` on the `ConversationMessage` as before.

_Bot message path (replaces thread-based lookup):_

- Guard: `agentMetadata` is present (adapter already enforced this, but assert defensively).
- Resolve parent: `ConversationModel.getMessage(store, agentMetadata.parent_channel, agentMetadata.parent_ts)` → `?ConversationMessage`.
  - If `null` (parent pruned or never stored): log warn and discard — treat as orphaned message with no recoverable context.
- Read `parentMsg.userAuthContext` — this is the auth context of the message that triggered this reply.
  - If `null` (parent message not yet authenticated at storage time): discard — context is unresolvable.
- Enforce pre-conditions from parent context:
  - `forceTerminated == true` → discard/skip event.
  - No valid `::agentname` reference in current message → discard/skip event.
- Derive new round: `newRound = parent.userAuthContext.roundCount + 1`.
- Hard ceiling: `newRound >= MAX_AGENT_ROUNDS` → set `forceTerminated = true`, store, and terminate session.
- Build new context via `withRound(parentCtx, newRound, false, ?{ channelId = agentMetadata.parent_channel; ts = agentMetadata.parent_ts })`.
- Store on the current `ConversationMessage`; proceed to routing.
- No more `saveRoundContext` / `lookupRoundContext` calls.

**1.5.7 — Remove `roundContexts` from `ChannelStore`**

- Remove `roundContexts : Map<Text, UserAuthContext>` from `ChannelStore` in `conversation-model.mo`.
- Delete `saveRoundContext` and `lookupRoundContext` public functions.
- Update `pruneChannel` — the separate `roundContexts` prune loop is removed; round context lifetime is now tied to the `ConversationMessage` that carries it.
- Add `getMessage(store, channelId, ts) : ?ConversationMessage` helper (O(log N + log M)) — needed by the new bot-message path. Checks `timeline` directly for `#post` or walks the `replyIndex` → `#thread` lookup.

**1.5.8 — Update agent reply call sites**

Everywhere a service calls `SlackWrapper.postMessage` to deliver an agent reply, pass:

```motoko
metadata = ?{
  event_type = "looping_agent_message";
  event_payload = {
    parent_agent = "::" # referencedAgent.name;
    parent_ts = triggeringMsg.ts;
    parent_channel = triggeringMsg.channel;
  };
};

```

#### Tests to delete

- All `saveRoundContext` / `lookupRoundContext` suites in `conversation-model.test.mo`.
- All `ConversationModel - round context pruned with timeline` suites.
- `SlackAuthMiddleware - withRound` tests that rely on the old arity (update, not delete).
- `MessageHandler` bot-message path tests that seed round context via `threadTs` — replace with metadata-bearing payloads.

#### Tests to add

- **Metadata parsing** (`slack-adapter`): present, absent, malformed `event_type`, missing payload fields.
- **Own-bot filter** (`slack-adapter`): own-bot without metadata → skip; own-bot with metadata → allow; own-bot with `threadTs` but no metadata → skip (threadTs no longer the gate).
- **Round derivation** (`message-handler`): round N = parent `roundCount + 1`; orphaned parent (parent_ts not in store) → discard; `forceTerminated` on parent → discard.
- **DM round tracking**: bot reply in a DM channel (no `threadTs`) with valid metadata → full round-tracking flow succeeds.
- **`getMessage` helper**: post lookup, reply lookup via replyIndex, missing → null.
- **`UserAuthContext` chain invariant**: `parentRef == null ↔ roundCount == 0`; chain terminates correctly.

~~### 1.6 — Agent Router~~

**Goal**

Introduce a dedicated `AgentRouter` module that sits between `MessageHandler` and the agent services. `MessageHandler` already handles round tracking, pre-condition guards, and conversation persistence (1.4 + 1.5). The router's sole responsibility is: given a validated `UserAuthContext` and a list of referenced agents, select the right service and invoke it. This is the clean separation between _who-is-allowed-to-act_ (already solved) and _what-acts-and-how_.

**Current State**

- `MessageHandler` calls `WorkspaceAdminOrchestrator.orchestrateAdminTalk` directly, hard-wiring a single service.
- Round tracking, force-termination guard, and agent-ref extraction all live in `MessageHandler`, which is correct per 1.5.
- When `MAX_AGENT_ROUNDS` is hit, the handler logs, stamps the terminated context, and returns — no user-facing message is posted yet (a `// Phase 1.6 will post a continuation prompt to Slack here` comment marks the gap).
- `buildReplyMetadata` in `MessageHandler` uses `"::admin"` as a fallback `parent_agent` — placeholder left by 1.5 for the router to replace.
- Only one agent category service exists: `WorkspaceAdminOrchestrator` (category `#admin`). Categories `#research` and `#communication` have no service yet.
- `AgentRecord.category` is defined and stored in the registry but never used at dispatch time — routing is unconditional.

**Desired State**

- New module `src/open-org-backend/events/agent-router.mo` is the single call site for agent service dispatch.
- `MessageHandler.handle` extracts the valid-agents list (already computed at the pre-condition guard), resolves the primary agent, and delegates to `AgentRouter.route` instead of calling `WorkspaceAdminOrchestrator` directly.
- `AgentRouter.route` dispatches based on `AgentRecord.category`:
  - `#admin` → `WorkspaceAdminOrchestrator.orchestrateAdminTalk` (existing).
  - `#research` / `#communication` → returns `#err("category service not yet implemented")` (stub, replaced in 1.7).
- When `MAX_AGENT_ROUNDS` is reached, `MessageHandler` calls a new `AgentRouter.postTerminationPrompt` to send a user-facing Slack message asking whether to continue.
- `buildReplyMetadata` uses `"::" # primaryAgent.name` as `parent_agent` on all outgoing replies. This is the agent that produced the reply and is therefore the agent that should handle any follow-up message that references it.

**Primary Agent Selection**

A message may reference multiple `::agentname` patterns. The router picks only one agent per event — the _primary agent_ — using this precedence:

1. First valid agent extracted by `AgentRefParser.extractValidAgents` (left-to-right in the message text).

Multi-agent fan-out (dispatching to several agents in one round) is out of scope for this task; it is deferred to Phase 5.

**Termination Prompt**

When a session is force-terminated by `MAX_AGENT_ROUNDS`, the bot posts a message in the same channel (in the same thread if `threadTs != null`):

```
⚠️ I've reached the maximum number of steps for this session. Reply with **continue** (or **::agentname continue**) in this thread to allow me to keep going.
```

- New function `AgentRouter.postTerminationPrompt(botToken, channel, threadTs)` calls `SlackWrapper.postMessage` with no metadata and no reply metadata (this message is not a round response — it must not re-trigger round tracking).
- `MessageHandler` passes `botToken` to this function after deriving it from the secret store — the token is already available at that point in the handler.

**Source Steps**

1. **`src/open-org-backend/events/agent-router.mo`** — new module:
   - Public type alias `RouteResult = WorkspaceAdminOrchestrator.OrchestratorResult` (or define a shared result type; pick whatever avoids creating a new type for now).
   - `public func route(primaryAgent : AgentModel.AgentRecord, …) : async RouteResult` — dispatches on `primaryAgent.category`; `#research`/`#communication` return `#err({message = "category not implemented"; steps = []})`.
   - `public func postTerminationPrompt(botToken : Text, channel : Text, threadTs : ?Text) : async ()` — posts the fixed termination message via `SlackWrapper.postMessage` with no metadata.
   - `public func findPreviousSameAgentReply(store, channel, startTs, agentName) : ?ConversationMessage` — walks the `parentRef` chain; returns first message with matching `agentMetadata.parent_agent`, or `null`.

2. **`src/open-org-backend/events/handlers/message-handler.mo`** — changes:
   - Remove direct import of `WorkspaceAdminOrchestrator`; add `import AgentRouter "../agent-router"`.
   - **Primary agent resolution** — two paths:
     - _Bot message_: `primaryAgent` is resolved from `agentMetadata.event_payload.parent_agent` via registry `lookupByName`. If not found in registry, discard (log warn).
     - _User message_: extract via `AgentRefParser.extractValidAgents(msg.text, ...)` and take the first, or fall back to `registry.getFirstByCategory(#admin)` for bare messages with no `::` ref.
   - Replace the `WorkspaceAdminOrchestrator.orchestrateAdminTalk(...)` call with `AgentRouter.route(primaryAgent, …)`.
   - Replace the `// Phase 1.6 will post a continuation prompt to Slack here` comment with a call to `AgentRouter.postTerminationPrompt`.
   - Fix `buildReplyMetadata`: replace the `"::admin"` fallback with `"::" # primaryAgent.name`. This correctly identifies the replying agent so that any subsequent message referencing this reply routes to the right agent.

3. **`dfx build open-org-backend --check`** — no compilation errors.

**Test Steps**

All tests in `tests/unit-tests/open-org-backend/`. Add a new file `agent-router.test.mo` and extend the existing `message-handler.test.mo`.

_`agent-router.test.mo`_

- **`route` — `#admin` category → calls orchestrator stub and returns result**.
- **`route` — `#research` category → returns `#err` with "not implemented" message**.
- **`route` — `#communication` category → returns `#err` with "not implemented" message**.
- **`postTerminationPrompt` — posts correct message text** (verify via cassette or mock).

_`message-handler.test.mo` additions_

- **MAX_AGENT_ROUNDS termination prompt**: send a bot message at round `MAX_AGENT_ROUNDS - 1` → handler posts termination prompt (previously just returned with a log).
- **Primary agent from user message with `::` reference**: user sends `"::research what is X"` → primary agent resolves to the registered research agent.
- **Primary agent fallback for bare user message**: user sends `"what is X"` (no `::` ref) → falls back to the first `#admin` agent in the registry.
- **`buildReplyMetadata` uses replying agent name**: regardless of which agent triggered this round, outgoing reply metadata always has `parent_agent = "::" # primaryAgent.name`. E.g. if `::admin` produces the reply, `parent_agent = "::admin"` — never the name of whoever called it.
- **`findPreviousSameAgentReply` — chain walk**: three-message chain `user → ::admin reply → ::research reply → ::admin reply (current)` — walk from current's `parent_ts` finds the prior `::admin` reply (skipping the intervening `::research` message).

### 1.7 — Refactor current service into generic agent service

- Refactor `GroqWorkspaceAdminService` into a generic agent service that reads agent config from the registry.
- The agent's `category`, `llmModel`, `toolsAllowed`, and `sources` drive execution rather than hardcoded values.
- This is the single agent service for Phase 2; category-specific services come later.

### 1.8 — Session tracking model

- New persistent model: `Map<slackMessageId, SessionRecord>`.
- `SessionRecord = { sessionId, slackMessageId, userAuthContextId, agentId, parentSessionId }`.
- `sessionId` format: `{agent_name}_{user_id}_{unique_incremental_id}`.
- `parentSessionId`: links to the session that triggered this one (forms delegation chain).
- Support delegation chain reconstruction by walking `parentSessionId` links.
- Retention policy: bounded by time or count (TBD).

---

## Phase 2 — Slack-Only Write Surface

**Goal**: Ensure all mutations enter through Slack events. Remove any remaining update call endpoints exposed to external clients.

### 2.1 — Audit and remove external update methods

- Review all `public shared` methods in `main.mo`.
- Remove or gate any `update` method that isn't `http_request_update`.
- Ensure `http_request` (query) and `http_request_update` are the only entry points.

### 2.2 — Access scoping on models

- Add visibility metadata to models: `read: #org | #team | #admin`, `write: #org | #team | #admin`.
- Enforce at the service level: check `userAuthContext.workspaceScopes` (and `isOrgAdmin` for org-level resources) against the resource's required level before read/write operations.
- Examples: objectives (`read: org`, `write: admin`), tasks (`read: org`, `write: team`).

### 2.3 — App install and setup flow

- On canister init or first Slack event: call `conversations.list` + `users.list`.
- Identify Primary Owner (`is_primary_owner: true`).
- Detect or request creation of `#looping-ai-org-admins`.
- Store channel ID anchor. Populate org admin user cache entries.

### 2.4 — Remove legacy auth

- Delete Principal-based admin management endpoints (`addOrgAdmin`, `removeOrgAdmin`, `addWorkspaceAdmin`, etc.).
- Delete old `AuthMiddleware`.
- Remove `orgOwner: Principal`, `orgAdmins: [Principal]`, `workspaceAdmins: Map<Nat, [Principal]>`, `workspaceMembers: Map<Nat, [Principal]>` from persistent state.
- Clean break — no migration path needed (no production deployment).

---

## Phase 3 — Auth Tokens & Read Surface

**Goal**: Implement short-lived, resource-based tokens for external read access.

### 3.1 — Token generation service

- Generate tokens inside the canister, triggered by a Slack DM command.
- Token maps to: `{ slackUserId, isOrgAdmin, workspaceScopes: Map<workspaceId, #admin | #member>, resourceScope, expiry: now + 1h }`.
- Cryptographically random token ID.

### 3.2 — Token storage model

- Persistent `Map<tokenId, TokenRecord>`.
- Bounded size (max tokens per user, max total tokens).
- Auto-purge on expiry (check on access + periodic timer cleanup).

### 3.3 — Token-gated query methods

- Query methods validate token: exists, not expired, scoped to requested resource.
- Return only aggregated stats and resource summaries — no personal/sensitive data.
- Log token usage for audit.

### 3.4 — Token generation Slack UX

- User sends a DM command to the bot.
- Bot resolves `userAuthContext`, generates token, replies with token/link.
- Frontend provides an easy-to-copy Slack prompt for re-requesting expired tokens.

---

## Phase 4 — Tools Redesign

**Goal**: Implement category-based tool scoping and per-agent tool state.

### 4.1 — Category tools enum system

- Each agent category service defines `category_tools`: an array of tool enum variants.
- Tool enums include access level requirement (`#org`, `#team`, `#admin`).
- Agent Router enforces: the tool's required level must be ≤ the user's access level.

### 4.2 — Per-agent tools configuration

- `toolsAllowed`: subset of category tools this agent can use (configurable per agent).
- `toolsState`: per-tool runtime state with `usageCount` and `knowHow: Text`.
- `knowHow` contains: configuration state, secret key references, good/bad practices, doc links, tool-specific operational knowledge.

### 4.3 — Tool scoping enforcement

- At Agent Router / service level: before executing a tool call, check the tool's required access level against `userAuthContext.workspaceScopes` for the relevant workspace (or `isOrgAdmin` for org-scoped tools).
- Reject tool calls that exceed the user's scope with a clear error message.

### 4.4 — Agent template duplication

- When creating a new agent: option to duplicate an existing agent's `toolsAllowed` and `toolsState` (including `knowHow`) as a starting template.
- Exposed through Slack interactive components (future — Phase 6).

---

## Phase 5 — Specialized Agent Services

**Goal**: Split the generic agent service into category-specific services based on real usage patterns.

### 5.1 — Identify category boundaries

- Review agent usage data to determine natural groupings.
- Define 2–3 initial categories (e.g., `#admin`, `#research`, `#communication`).

### 5.2 — Implement category services

- Each service inherits the generic execution loop but customizes:
  - `category_tools` definition.
  - LLM model selection and prompt strategy.
  - Knowledge source configuration.
  - Skill-specific pre/post processing.

### 5.3 — Agent-to-agent delegation with specialized services

- Ensure the Agent Router correctly dispatches to the right category service based on the referenced agent's `category`.
- Validate that `userAuthContext` inheritance works across category boundaries.

---

## Phase 6 — Interactive Messages & UX Polish

**Goal**: Support interactive Slack components for configuration and onboarding.

### 6.1 — Interactive message support in Slack adapter

- Parse `block_actions` and `view_submission` payloads.
- Add new event types to the normalized event model.
- Route to new handlers in the event router.

### 6.2 — Primary Owner onboarding flow

- Interactive message asking the Primary Owner to set up `#looping-ai-org-admins` (if not already present).
- Guided workspace creation: name, admin channel, member channel selection from list.
- Channel list shows public channels and private channels where bot has access.
- Manual channel ID entry option with `/invite @looping` guidance if not accessible.

### 6.3 — Agent configuration via interactive components

- Admin-initiated agent creation/editing through Slack interactive messages.
- Tool permission configuration: select from `category_tools` which tools to allow.
- Agent duplication (template): copy `toolsAllowed` and `toolsState` from an existing agent.

### 6.4 — Split-reply UX

- After the LLM generates a response, inspect processing steps for access level usage.
- If a higher access level than the channel's scope was used:
  - Send a generic safe acknowledgement in the original channel.
  - Deliver the detailed reply in the user's DM or the appropriate scoped channel.
- If no scope escalation: reply normally in the original channel.

---

## Cross-cutting Concerns (apply throughout all phases)

### Testing

- Each phase should include tests for its new functionality.
- Slack API calls tested via cassettes (mocked HTTP responses).
- SlackAuthMiddleware tested with simulated user cache states.
- Agent routing and round control tested with multi-hop scenarios.

### Constants

- `MAX_AGENT_ROUNDS = 10` (hard ceiling on agent rounds per session)
- `AUTH_TOKEN_EXPIRY_NS` (1 hour in nanoseconds)
- `WEEKLY_RECONCILIATION_DAY = #sunday`

### Retention and cleanup

- Session records: retention policy TBD (bounded by time or count).
- Auth tokens: auto-purge on expiry via periodic timer.
- User cache entries: updated on every sync, stale entries cleaned on weekly reconciliation.
