# Agent Session Refactor — Implementation Plan

Target schema: [agent-session-schema.md](agent-session-schema.md)

## Current State

Round tracking lives in `UserAuthContext.{roundCount, forceTerminated, parentRef}` on `ConversationMessage`. There is **no persistent session/turn/trace store**. The message handler walks `parentRef` backward through conversation entries to reconstruct the delegation chain and advance round count. `ProcessingStep` (`{ action, result, timestamp }`) is the only trace mechanism — ephemeral, returned inline in handler results.

## Scope

Since the canister will be reinstalled (no migration), this is a clean-slate refactor of how agent execution is tracked. The conversation store continues the same thing — channel-keyed message timeline. Sessions, turns, and traces are new first-class stores.

---

## Phases

### Phase 1: Types & Models (foundation)

**Goal**: Define the new types and create the three stores (sessions, turns, traces) with CRUD functions. No callers changed yet — this phase compiles independently.

#### 1a. New types in `types.mo`

Add at the bottom of the module:

```motoko
// ============================================
// Agent Session Types
// ============================================

public type TurnStatus = { #running; #succeeded; #failed };

public type SourceRef = {
  #slack : { channelId : Text; ts : Text };
  #github : { runId : Text; workflowId : Text };
  #timer : { label : Text };
};

public type TurnCost = {
  promptTokens : Nat;
  completionTokens : Nat;
  estimatedMicroUnits : Nat;
};

public type TraceDetail = {
  #contextAssembled : {
    summaryTokens : Nat;
    rawTurnsIncluded : Nat;
    channelSnippets : Nat;
  };
  #llmCall : {
    model : Text;
    durationMs : Nat;
    finishReason : Text;
    content : ?Text;
    thinking : ?Text;
    toolRequests : ?[{ name : Text; input : Text }];
    cost : TurnCost;
  };
  #toolCall : {
    name : Text;
    input : Text;
    output : Text;
    success : Bool;
    durationMs : Nat;
  };
  #slackPost : { channelId : Text; threadTs : ?Text; ts : Text };
  #roundLimitHit;
  #policyRejection : { reason : Text };
  #faultRecovered : { error : Text };
};

```

Also extend `AgentMetadataPayload`:

```motoko
public type AgentMetadataPayload = {
  parent_agent : Text;
  parent_ts : Text;
  parent_channel : Text;
  turn_id : ?Text; // The turnId that produced this reply. null for legacy messages.
};

```

#### 1b. New file: `models/session-model.mo`

Session CRUD and turn management. Contains the types that need `List`/`Map` imports (`CompactionState`, `SessionPolicy`, `AgentSessionRecord`, `AgentTurnRecord`, `TurnTraceEntry`).

Key functions:

| Function               | Signature                                                                        | Purpose                                        |
| ---------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- |
| `emptyStores`          | `() → SessionStores`                                                             | Create all three empty stores                  |
| `getOrCreateSession`   | `(stores, agentId) → AgentSessionRecord`                                         | Lazy init: session created on first turn       |
| `createTurn`           | `(stores, agentId, sourceRef, triggerTurnId, userAuthContext) → AgentTurnRecord` | Append turn, advance `nextTurnNumber`          |
| `completeTurn`         | `(stores, turnId, status, cost, errorSummary) → ()`                              | Finalize a turn with terminal status           |
| `appendSlackReplyTs`   | `(stores, turnId, ts) → ()`                                                      | Append a Slack reply ts during the turn        |
| `appendTrace`          | `(stores, turnId, detail) → ()`                                                  | Append a trace entry with auto-incremented seq |
| `getTurnsByAgent`      | `(stores, agentId) → List<AgentTurnRecord>`                                      | Read all turns for an agent                    |
| `getTraces`            | `(stores, turnId) → List<TurnTraceEntry>`                                        | Read all traces for a turn                     |
| `deleteTurnsOlderThan` | `(stores, cutoffNs) → Nat`                                                       | Hard-delete turns + traces older than cutoff   |

The `SessionStores` record bundles the three maps:

```motoko
public type SessionStores = {
  sessions : Map.Map<Nat, AgentSessionRecord>; // keyed by agentId
  turns : Map.Map<Nat, List<AgentTurnRecord>>; // keyed by agentId
  traces : Map.Map<Text, List<TurnTraceEntry>>; // keyed by turnId
};

```

**Design decision**: One module, one `SessionStores` record (not three separate models). The three stores are tightly coupled — turn creation touches sessions and turns atomically, and trace append references `turnId`. A single module keeps invariants local.

#### Files touched

| File                                             | Change                                                                                  |
| ------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `src/control-plane-core/types.mo`                | Add `TurnStatus`, `SourceRef`, `TurnCost`, `TraceDetail`; extend `AgentMetadataPayload` |
| `src/control-plane-core/models/session-model.mo` | **New file**. All session/turn/trace types, stores, CRUD                                |

#### Verification

```bash
icp build control-plane-core
```

---

### Phase 2: Slim `UserAuthContext`

**Goal**: Remove session state from auth context. This is a **breaking change** — code that reads `roundCount`, `forceTerminated`, or `parentRef` will stop compiling. Phase 3 fixes those call sites.

#### Changes to `slack-auth-middleware.mo`

```motoko
// BEFORE
public type UserAuthContext = {
  slackUserId : Text;
  isPrimaryOwner : Bool;
  isOrgAdmin : Bool;
  workspaceScopes : Map.Map<Nat, SlackUserModel.WorkspaceScope>;
  roundCount : Nat;
  forceTerminated : Bool;
  parentRef : ?{ channelId : Text; ts : Text };
};

// AFTER
public type UserAuthContext = {
  slackUserId : Text;
  isPrimaryOwner : Bool;
  isOrgAdmin : Bool;
  workspaceScopes : Map.Map<Nat, SlackUserModel.WorkspaceScope>;
};

```

- **Remove** `buildFromCache` default round fields.
- **Remove** `withRound` function entirely.
- **Keep** `authorize` unchanged (doesn't touch round fields).

#### Files touched

| File                                                         | Change                                                                                                     |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `src/control-plane-core/middleware/slack-auth-middleware.mo` | Remove `roundCount`, `forceTerminated`, `parentRef` from type; remove `withRound`; update `buildFromCache` |

#### Verification

Won't compile yet — dependent files still reference removed fields. Move straight to Phase 3.

---

### Phase 3: Wire stores into the pipeline

**Goal**: Add `SessionStores` to the processing context and `main.mo`. Fix all compilation errors from Phase 2.

#### 3a. `EventProcessingContext`

Add `sessionStores : SessionModel.SessionStores` to the record.

#### 3b. `main.mo`

- Import `SessionModel`.
- Declare `let sessionStores = SessionModel.emptyStores();` as persistent state.
- Add `sessionStores` to the `EventProcessingContext` construction in `makeEventProcessor`.

#### 3c. Fix `ConversationMessage.userAuthContext`

The `ConversationMessage` type carries `?UserAuthContext`. After Phase 2 the type is smaller. No fields were _added_, only removed, so no changes to `ConversationModel` types are needed. But code in `message-handler.mo` that reads `userAuthContext.roundCount` etc. will break — those call sites are fixed in Phase 4.

#### Files touched

| File                                                              | Change                                                                              |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `src/control-plane-core/events/types/event-processing-context.mo` | Add `SessionModel` import; add `sessionStores` field                                |
| `src/control-plane-core/main.mo`                                  | Import `SessionModel`; declare `sessionStores`; add to `makeEventProcessor` context |

#### Verification

Still won't compile fully — message handler reads removed fields. Continue to Phase 4.

---

### Phase 4: Refactor `message-handler.mo` (core)

**Goal**: Replace the `parentRef` chain-walk round advancement with session/turn creation. This is the largest single change.

#### Current flow → new flow

| Phase          | Current                                                              | New                                                                                                                                                                                                      |
| -------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.4            | Store message, `userAuthContext = null`                              | Same — no change                                                                                                                                                                                         |
| 1.5 (user msg) | `buildFromCache → UserAuthContext(round=0)`                          | `buildFromCache → UserAuthContext` (identity only) + `SessionModel.createTurn(sourceRef=#slack, triggerTurnId=null)`                                                                                     |
| 1.5 (bot msg)  | Walk `parentRef` → advance `roundCount` → check `MAX_AGENT_ROUNDS`   | Extract `turn_id` from `agentMetadata` → `SessionModel.createTurn(sourceRef=#slack, triggerTurnId=turn_id)` → check round ceiling via turn count walk on `triggerTurnId` (bounded by `MAX_AGENT_ROUNDS`) |
| 1.5 stamp      | `updateMessageContext(authCtx with round)`                           | `updateMessageContext(authCtx identity only)`                                                                                                                                                            |
| 1.6 dispatch   | `AgentRouter.route(... conversationEntry ...)`                       | `AgentRouter.route(... turnId, sessionStores ...)`                                                                                                                                                       |
| 1.6 reply      | `postAgentReply(metadata={parent_agent, parent_ts, parent_channel})` | `postAgentReply(metadata={parent_agent, parent_ts, parent_channel, turn_id})` + `SessionModel.appendSlackReplyTs` + `SessionModel.appendTrace(#slackPost)`                                               |

#### Round ceiling check (replaces `parentRef` walk)

Instead of walking conversation messages via `parentRef`, count rounds by walking `triggerTurnId`:

```motoko
func countDelegationDepth(stores, triggerTurnId) : Nat {
  var depth = 0;
  var current = triggerTurnId;
  loop {
    switch (current) {
      case (null) { return depth };
      case (?tid) {
        depth += 1;
        if (depth >= Constants.MAX_AGENT_ROUNDS) { return depth };
        let turn = SessionModel.findTurn(stores, tid);
        current := switch (turn) {
          case (?t) { t.triggerTurnId };
          case (null) { null };
        };
      };
    };
  };
};

```

This is bounded by `MAX_AGENT_ROUNDS` (10), so never > 10 iterations.

#### `resolveRoundContext` replacement

Rename to `resolveAndCreateTurn`. Returns `{ authCtx : UserAuthContext; turn : AgentTurnRecord }` or short-circuits.

#### `resolvePrimaryAgent` — unchanged

Agent resolution stays the same (parsed from `::agentname` or `agentMetadata`).

#### `dispatchToAgentRouter` — signature change

Pass `turnId` and `sessionStores` instead of relying on `UserAuthContext` to carry round info.

#### `postAgentReply` — embed `turn_id`

The `AgentMetadataPayload` now carries `turn_id`. The adapter already parses whatever fields exist.

#### Files touched

| File                                                        | Change type                                                                                                                                                                   |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/control-plane-core/events/handlers/message-handler.mo` | **Major rewrite** of `resolveRoundContext`, `resolveBotRoundContext`, `postAgentReply`. New `countDelegationDepth`. Remove `parentRef`-walk code.                             |
| `src/control-plane-core/events/agent-router.mo`             | Signature change: accept `turnId`, `sessionStores`. Remove `findPreviousSameAgentReply` (no longer needed — LLM context will come from session turns, not conversation walk). |

#### Verification

```bash
icp build control-plane-core
```

Should compile after this phase, assuming agent services also get their signatures updated (Phase 5).

---

### Phase 5: Agent execution pipeline — trace emission

**Goal**: The LLM loop and tool executor emit trace entries instead of (or in addition to) ephemeral `ProcessingStep`.

#### 5a. `agent-orchestrator.mo` — pass turn context

- Accept `turnId`, `sessionStores` in `orchestrateAgentTalk` signature.
- Pass through to agent `process()` functions.

#### 5b. Agent services (`org-admin-agent.mo`, `work-planning-agent.mo`)

Each agent service runs the multi-turn LLM loop. Changes within the loop:

| Current step                            | New trace emission                                                                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `OpenRouterWrapper.reason(...)` returns | `SessionModel.appendTrace(stores, turnId, #llmCall { model, durationMs, finishReason, content, thinking, toolRequests, cost })` |
| `ToolExecutor.execute(...)` returns     | For each tool result: `SessionModel.appendTrace(stores, turnId, #toolCall { name, input, output, success, durationMs })`        |
| Max iterations exceeded                 | `SessionModel.appendTrace(stores, turnId, #roundLimitHit)`                                                                      |
| LLM API error                           | `SessionModel.appendTrace(stores, turnId, #faultRecovered { error })`                                                           |

The `ProcessingStep` list can be kept temporarily for backward compatibility with event store `processingLog`, or removed. Recommend keeping it for now (cheap, and the event store already relies on it).

#### 5c. `tool-executor.mo` — measure duration

Add timing around tool execution:

```motoko
let startNs = Time.now();
let result = await tool.handler(call.arguments);
let durationMs = (Time.now() - startNs) / 1_000_000;

```

Return `durationMs` alongside result so the caller can emit the trace.

**Note**: The tool executor itself does NOT write to session stores. The calling agent service does — this keeps the executor stateless and testable.

#### 5d. Turn finalization

After the LLM loop completes (text response, error, or max iterations):

```motoko
let cost = aggregateCostFromTraces(stores, turnId);
SessionModel.completeTurn(stores, turnId, status, ?cost, errorSummary);

```

The `aggregateCostFromTraces` helper sums `promptTokens` and `completionTokens` from all `#llmCall` traces in this turn.

#### Files touched

| File                                                            | Change type                                                                                                |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `src/control-plane-core/orchestrators/agent-orchestrator.mo`    | Signature change: add `turnId`, `sessionStores`                                                            |
| `src/control-plane-core/agents/admin/org-admin-agent.mo`        | Add `turnId`, `sessionStores` to `process()`. Emit trace entries in LLM loop. Call `completeTurn` on exit. |
| `src/control-plane-core/agents/planning/work-planning-agent.mo` | Same as org-admin-agent                                                                                    |
| `src/control-plane-core/agents/helpers.mo`                      | Add `aggregateCostFromTraces` helper                                                                       |
| `src/control-plane-core/tools/tool-executor.mo`                 | Return `durationMs` per tool result                                                                        |
| `src/control-plane-core/tools/tool-types.mo`                    | Add `durationMs : Nat` to `ToolResult`                                                                     |

#### Verification

```bash
icp build control-plane-core
```

---

### Phase 6: Metadata evolution

**Goal**: `AgentMetadataPayload` carries `turn_id`. Slack adapter parses it on inbound events.

#### 6a. `slack-adapter.mo` — parse `turn_id`

In `parseAgentMetadata`, extract the optional `turn_id` field from the JSON payload. Return it in `AgentMetadataPayload`.

#### 6b. `slack-wrapper.mo` — serialize `turn_id`

In `postMessage`, when building the metadata JSON, include `turn_id` if present.

#### 6c. Downstream handler

`message-handler.mo` already uses `agentMetadata` — it will now read `turn_id` and pass it as `triggerTurnId` to `SessionModel.createTurn`. This was covered in Phase 4.

#### Files touched

| File                                               | Change type                          |
| -------------------------------------------------- | ------------------------------------ |
| `src/control-plane-core/events/slack-adapter.mo`   | Parse `turn_id` from metadata JSON   |
| `src/control-plane-core/wrappers/slack-wrapper.mo` | Serialize `turn_id` in metadata JSON |
| `src/control-plane-core/types.mo`                  | Already done in Phase 1a             |

#### Verification

```bash
icp build control-plane-core
```

---

### Phase 7: Timers

**Goal**: Add the turn cleanup timer (3-month hard-delete). Session compaction is a future phase (depends on LLM summarization — not in scope for this refactor).

#### 7a. New file: `timers/turn-cleanup-runner.mo`

```motoko
public func run(stores : SessionModel.SessionStores) : {
  #ok : Nat;
  #err : Text;
} {
  let cutoff = Time.now() - TURN_CLEANUP_RETENTION_NS;
  let deleted = SessionModel.deleteTurnsOlderThan(stores, cutoff);
  #ok(deleted);
};

```

#### 7b. `constants.mo`

Add:

```motoko
// 3 months in nanoseconds (90 * 24 * 60 * 60 * 1_000_000_000)
public let TURN_CLEANUP_RETENTION_NS : Nat = 7_776_000_000_000_000;

// 1 hour in nanoseconds — threshold for read-time trace truncation
// (already exists as ONE_HOUR_NS, just alias or document usage)
public let TRACE_RETENTION_NS : Nat = ONE_HOUR_NS;

```

#### 7c. `main.mo` — register timer

Add a `TimerRegistryEntry` for `turn-cleanup` with interval = `THIRTY_DAYS_NS` (runs monthly).

#### Files touched

| File                                                   | Change type                                           |
| ------------------------------------------------------ | ----------------------------------------------------- |
| `src/control-plane-core/timers/turn-cleanup-runner.mo` | **New file**                                          |
| `src/control-plane-core/constants.mo`                  | Add `TURN_CLEANUP_RETENTION_NS`, `TRACE_RETENTION_NS` |
| `src/control-plane-core/main.mo`                       | Add timer registry entry + timestamp variable         |

#### Verification

```bash
icp build control-plane-core
```

---

### Phase 8: Remove `ProcessingStep` from event store (cleanup, optional)

**Goal**: Event store currently persists `processingLog : [ProcessingStep]` on every event. With traces in session stores, this is redundant. This phase is optional — can keep both for now.

**If proceeding**: Remove `processingLog` from `EventStoreModel.Event`, remove all `ProcessingStep` array threading from handlers. Simplify handler return types to just `{ #ok; #err : Text }`.

**Recommendation**: Defer this to a future cleanup pass. The event store's `processingLog` is lightweight and useful for debugging events that don't reach agent execution (e.g., failed parsing, dedup rejections).

---

### Phase 9: Tests

**Goal**: Update existing tests and add new ones for the session model.

#### 9a. New Motoko unit tests

Add tests for `session-model.mo` via `mops test`:

- `getOrCreateSession` creates on first call, returns existing on second
- `createTurn` advances `nextTurnNumber`, sets deterministic `turnId`
- `completeTurn` sets terminal status and cost
- `appendTrace` increments seq monotonically
- `deleteTurnsOlderThan` removes old turns and their traces

#### 9b. Update existing unit tests

- **`message-handler.spec.ts`**: Update to expect session/turn creation instead of `roundCount` advancement. Verify `turn_id` in metadata. Test round ceiling via `triggerTurnId` chain.
- **`slack-wrapper.spec.ts`**: Verify `turn_id` serialization in metadata.

#### 9c. Integration tests

- **`http-request-update.spec.ts`**: Verify end-to-end flow: webhook → session created → turn created → traces emitted → reply with `turn_id` metadata.

#### Files touched

| File                                                                         | Change type                        |
| ---------------------------------------------------------------------------- | ---------------------------------- |
| `test/session-model.test.mo` or `tests/unit-tests/.../session-model.spec.ts` | **New** — session model unit tests |
| `tests/unit-tests/.../message-handler.spec.ts`                               | Update assertions for new flow     |
| `tests/unit-tests/.../slack-wrapper.spec.ts`                                 | Update metadata assertions         |
| `tests/integration-tests/.../http-request-update.spec.ts`                    | Update end-to-end assertions       |

#### Verification

```bash
mops test           # Motoko unit tests
bun run tsc --noEmit  # TypeScript type check
bun run test        # Full test suite (build + run)
```

---

## Dependency Graph

```
Phase 1 (types + session-model)
  ↓
Phase 2 (slim UserAuthContext)  ──→  Phase 3 (wire stores)
                                         ↓
                                    Phase 4 (message-handler refactor)
                                         ↓
                                    Phase 5 (trace emission in LLM loop)
                                         ↓
                                    Phase 6 (metadata evolution)
                                         ↓
                                    Phase 7 (timers)
                                         ↓
                                    Phase 9 (tests)

Phase 8 (ProcessingStep cleanup) — independent, deferrable
```

Phases 1–7 form a strict chain. Each phase depends on the previous one. The project won't compile until Phase 5 is complete (all `process()` signatures align).

**Practical bundling**: Phases 2 + 3 should be done together (breaking change + fix in one commit). Phases 4 + 5 + 6 form the core refactor and could be a single commit or broken into reviewable chunks.

---

## Files Summary

### New files (3)

| File                                                   | Phase |
| ------------------------------------------------------ | ----- |
| `src/control-plane-core/models/session-model.mo`       | 1b    |
| `src/control-plane-core/timers/turn-cleanup-runner.mo` | 7a    |
| Motoko unit test file for session model                | 9a    |

### Modified files (14)

| File                          | Phase  | Severity     |
| ----------------------------- | ------ | ------------ |
| `types.mo`                    | 1a, 6  | Medium       |
| `slack-auth-middleware.mo`    | 2      | Medium       |
| `event-processing-context.mo` | 3a     | Small        |
| `main.mo`                     | 3b, 7c | Small–Medium |
| `message-handler.mo`          | 4      | **Large**    |
| `agent-router.mo`             | 4      | Medium       |
| `agent-orchestrator.mo`       | 5a     | Medium       |
| `org-admin-agent.mo`          | 5b     | Medium       |
| `work-planning-agent.mo`      | 5b     | Medium       |
| `agents/helpers.mo`           | 5d     | Small        |
| `tool-executor.mo`            | 5c     | Small        |
| `tool-types.mo`               | 5c     | Small        |
| `slack-adapter.mo`            | 6a     | Small        |
| `slack-wrapper.mo`            | 6b     | Small        |
| `constants.mo`                | 7b     | Small        |

### Unchanged files

All other models (conversation-model, workspace-model, secret-model, etc.), utilities, instructions, and handlers other than message-handler.

---

## Risk & Mitigations

| Risk                                                                        | Mitigation                                                                                                            |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Large surface area — 14 files + 3 new                                       | Strict phase ordering; compile after each phase                                                                       |
| `message-handler.mo` is the most complex file and gets heaviest changes     | Phase 4 isolated; existing unit tests catch regressions                                                               |
| Session model needs to handle partial turn (crash mid-LLM-loop)             | `#running` status stays until `completeTurn`; timer never touches `#running` turns                                    |
| `triggerTurnId` walk for round ceiling could miss turns if metadata is lost | Fallback: if `turn_id` is null in metadata (legacy bot message), treat as root turn                                   |
| Tool executor `durationMs` measurement via `Time.now()` includes async wait | Acceptable — canister time advances only at message boundaries, so `durationMs` captures real wall time across awaits |
