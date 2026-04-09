# Agent Session Schema — Target Design

## Overview

Strict three-level hierarchy: **Agent Session → Turns → Trace Entries**. One persistent session per agent, append-only turns per session, immutable trace entries per turn. No session-parent chaining. Delegation lineage via turn-level `triggerTurnId`. Built-in compaction, read-time truncation, and timer-based cleanup.

## Persistent Stores

```
agentSessions : Map<AgentId, AgentSessionRecord>
agentTurns    : Map<AgentId, List<AgentTurnRecord>>
turnTraces    : Map<TurnId, List<TurnTraceEntry>>
```

No separate index for Slack → Turn lookup. Delegation lineage is carried via **Slack message metadata**: when the bot posts a reply, the `AgentMessageMetadata` payload includes the producing `turnId`. When a downstream agent's event arrives, the adapter extracts this `turnId` and sets it directly as `triggerTurnId` on the new turn.

## AgentSessionRecord

Key = `AgentId`. Exactly one per agent, always active. No `sessionId` (agent ID is the key), no status field, no timestamps (derivable from turns).

| Field            | Type              | Description                                                |
| ---------------- | ----------------- | ---------------------------------------------------------- |
| `agentId`        | `Nat`             | Foreign key / map key                                      |
| `nextTurnNumber` | `Nat`             | Sequence generator for deterministic `turnId` construction |
| `compaction`     | `CompactionState` | Summary layers and worker progress                         |
| `policy`         | `SessionPolicy`   | Budget and truncation settings                             |

### CompactionState

| Field                 | Type    | Description                                                                                                                          |
| --------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `hotSummary`          | `Text`  | Summary of compacted turns. Target budget: N/4 tokens                                                                                |
| `lastCompactedTurnId` | `?Text` | TurnId of the last turn folded into `hotSummary`. Serves as the compaction cursor. `null` = nothing compacted yet                    |
| `warmSummary`         | `?Text` | Compressed version of the previous `hotSummary`. Target budget: N/8 tokens                                                           |
| `coldSummary`         | `?Text` | Coarsening timeline: newest material is detailed, oldest becomes monthly → quarterly → annual granularity. Target budget: N/8 tokens |
| `lastWorkerRunAtNs`   | `?Int`  | When the maintenance worker last processed this session                                                                              |

### SessionPolicy

| Field                | Type  | Description                                                                                                                                                 |
| -------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `summaryTokenBudget` | `Nat` | Total token budget N for all session context at prompt time. Halving distribution: raw = N/2, hot = N/4, warm = N/8, cold = N/8                             |
| `maxTruncatedTokens` | `Nat` | Cap per text field when applying read-time truncation. The field is split: first M/2 chars + `[TRUNCATED]` + last M/2 chars, where M = `maxTruncatedTokens` |

## AgentTurnRecord

Appended to the agent's turn list. Never modified after completion (except `slackReplyTs` which grows during the turn and `cost`/`completedAtNs`/`status`/`errorSummary` set at finalization).

| Field             | Type                                                                               | Description                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `turnId`          | `Text`                                                                             | `"{agentId}_{turnNumber}"` — deterministic, no UUID needed                                                 |
| `agentId`         | `Nat`                                                                              | Denormalized for cross-agent queries                                                                       |
| `startedAtNs`     | `Int`                                                                              | Nanosecond timestamp at turn creation                                                                      |
| `completedAtNs`   | `?Int`                                                                             | Set when turn reaches terminal status                                                                      |
| `status`          | `#running \| #succeeded \| #failed`                                                | `#failed` covers force-termination, policy rejection, and errors — detail goes in `errorSummary`           |
| `sourceRef`       | `?(#slack { channelId; ts } \| #github { runId; workflowId } \| #timer { label })` | What triggered this turn. No `userId` — already in `userAuthContext`                                       |
| `triggerTurnId`   | `?Text`                                                                            | The immediately prior agent turn that caused this one (via delegation). `null` = user-originated root turn |
| `userAuthContext` | `UserAuthContext`                                                                  | Snapshot of permissions at turn start                                                                      |
| `cost`            | `?{ promptTokens : Nat; completionTokens : Nat; estimatedMicroUnits : Nat }`       | `null` while `#running`; always set on terminal status. Aggregated from `#llmCall` trace entries           |
| `slackReplyTs`    | `List<Text>`                                                                       | All Slack reply `ts` values posted during this turn, in order                                              |
| `errorSummary`    | `?Text`                                                                            | Human-readable error; set when `status = #failed`                                                          |

### Design notes

- **No `turnNumber` field** — derivable from `turnId`.
- **No `originTurnId`** — the root of a delegation chain can be found by walking `triggerTurnId` (bounded by `MAX_AGENT_ROUNDS = 10`). This is rare enough that single-digit hops are acceptable.
- **No `lineage` wrapper** — `triggerTurnId` is a top-level field since it is the only lineage field.

## TurnTraceEntry

Immutable after append. Trace entries are **never mutated or deleted by the worker**. Text fields are truncated at **read-time** when assembling LLM context (entries older than `TRACE_RETENTION_NS`). Full originals are preserved for compaction summaries and audit, until the turn cleanup timer deletes the entire turn.

| Field    | Type          | Description                                                        |
| -------- | ------------- | ------------------------------------------------------------------ |
| `seq`    | `Nat`         | Monotonic within turn, starts at 1                                 |
| `atNs`   | `Int`         | Nanosecond timestamp                                               |
| `detail` | `TraceDetail` | Self-contained variant — the variant tag IS the type discriminator |

### TraceDetail

Each variant is a complete, self-contained record of one finished operation. No started/finished pairing — 10 tool calls produce 10 `#toolCall` entries, each carrying its own input, output, duration, and success.

```
#contextAssembled {
  summaryTokens    : Nat
  rawTurnsIncluded : Nat
  channelSnippets  : Nat
}

#llmCall {
  model              : Text
  durationMs         : Nat
  finishReason       : Text                 -- "stop", "tool_calls", "error", etc.
  content            : ?Text                -- assistant text reply (truncatable at read-time)
  thinking           : ?Text                -- chain-of-thought / reasoning (truncatable at read-time)
  toolRequests       : ?[{ name : Text; input : Text }]   -- tools the LLM wants to call next
  cost               : { promptTokens : Nat; completionTokens : Nat; estimatedMicroUnits : Nat }
}

#toolCall {
  name       : Text
  input      : Text               -- (truncatable at read-time)
  output     : Text               -- (truncatable at read-time); carries error message when success = false
  success    : Bool
  durationMs : Nat
}

#slackPost {
  channelId : Text
  threadTs  : ?Text
  ts        : Text                -- the posted message's ts
}

#roundLimitHit                    -- no fields; context is in the turn's errorSummary

#policyRejection {
  reason : Text
}

#faultRecovered {
  error : Text
}
```

### Truncatable fields

When assembling LLM prompt context, the context assembler applies read-time truncation to these fields on entries where `atNs` is older than `TRACE_RETENTION_NS` (1 hour):

- `#llmCall.content`, `#llmCall.thinking`
- `#toolCall.input`, `#toolCall.output`

Truncation format: `first M/2 chars + " [TRUNCATED] " + last M/2 chars` where `M = policy.maxTruncatedTokens`.

The original values remain intact in storage for compaction and audit purposes.

## AgentMessageMetadata (evolved)

The existing Slack metadata payload (`parent_agent`, `parent_ts`, `parent_channel`) is extended with:

| Field    | Type   | Description                           |
| -------- | ------ | ------------------------------------- |
| `turnId` | `Text` | The `turnId` that produced this reply |

This allows the next agent's handler to set `triggerTurnId` directly from inbound metadata, with no index or lookup required.

## Compaction Flow

**Trigger**: when raw turns consume ≥ 90% of `summaryTokenBudget / 2`.

**Cascade** (each pass):

1. **Raw → Hot**: all raw turns since `lastCompactedTurnId` are summarized into a new `hotSummary` (replaces previous). `lastCompactedTurnId` advances atomically — this is the cursor and it ensures resumability.
2. **Old Hot → Warm**: the previous `hotSummary` is compressed into a new `warmSummary` (replaces previous).
3. **Old Warm → Cold**: the previous `warmSummary` is blended into `coldSummary`. The `coldSummary` is a coarsening timeline: newest events retain detail; oldest events are progressively grouped (days → months → quarters → years). Events are never fully dropped from `coldSummary` — only their granularity decreases.

**Halving budget distribution** (for `summaryTokenBudget = N`):

| Layer         | Budget | Purpose                               |
| ------------- | ------ | ------------------------------------- |
| Raw turns     | N/2    | Full fidelity recent turns            |
| `hotSummary`  | N/4    | Summary of recently compacted turns   |
| `warmSummary` | N/8    | Compressed previous hot-level summary |
| `coldSummary` | N/8    | Lifetime coarsening timeline          |

## Read-Time Truncation

Not a storage mutation. Applied during prompt context assembly:

- Entries older than `TRACE_RETENTION_NS` (1 hour, constant) have their truncatable text fields shortened for the LLM context window.
- Original values remain in storage untouched — needed for compaction summary and audit trail.

## Turn Cleanup Timer

A periodic timer (e.g., monthly) hard-deletes entire turns and their trace entries when the turn's `completedAtNs` is older than `TURN_CLEANUP_RETENTION_NS` (3 months, constant). This fully closes the data lifecycle:

1. **0 – 1h**: full fidelity (raw trace available to LLM context and compaction).
2. **1h – compaction**: trace preserved for compaction worker; LLM sees truncated version.
3. **After compaction**: turn content lives on inside summary layers; raw trace serves audit.
4. **After 3 months**: turn + traces hard-deleted. Summary layers are the permanent record.

## Prompt Context Assembly Order (oldest → newest)

1. `coldSummary` → `warmSummary` → `hotSummary` (compressed history layers)
2. Raw turns after `lastCompactedTurnId` (recent, uncompacted)
3. Channel history snippets (secondary enrichment)
4. Store / skill documents via embedding retrieval

## Invariants

1. **One `AgentSessionRecord` per `agentId`**. Map key uniqueness is the only enforcement needed.
2. **`turnId` = `"{agentId}_{nextTurnNumber}"`**. `nextTurnNumber` advances atomically on turn creation.
3. **`TurnTraceEntry.seq`** is monotonic per `turnId`. Entries are never removed or mutated.
4. **`cost`** is `null` while `status = #running`; always set on any terminal status.
5. **`triggerTurnId = null`** means this is a root turn (user-originated).
6. **Maintenance worker deletes all turns older than `TURN_CLEANUP_RETENTION_NS`** — including orphaned `#running` turns (e.g. from crashed workers). Compaction only processes completed turns.
