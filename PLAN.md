# PLAN.md — Looping AI Short-Term Planning

This plan describes the incremental path from the current codebase to the architecture described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Instructions

Each Phase is broken down into separate Tasks, each a separate development effort (separate PRs). Phases and Tasks are ordered by dependency, not priority — some later Phases may start in parallel with earlier ones where there are no blockers.

Each Phase is assigned a unique, sequential ID. Once a Task is fully completed, the Task at position n-2 can be safely deleted, retaining one prior Task for context.

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

Previous, not implemented, phases have been archived to [PLAN.archive.md](docs/plans/PLAN.archive.md).

---

## Plan: v0.5 — Filesystem

**TL;DR**: Build the Filesystem — a file-like persistent knowledge layer that each agent owns exclusively and can read from and write to — in two focused PRs: first the data model + admin tools (5.3), then the agent-facing `file_read`/`file_write` tools (5.4). GitHub integration remains deferred to a later version.

---

### 5.2.1 — Workflow-as-Engine-Tool with Approval Gate

**TL;DR**: Engine is the source of truth for a content-hashed workflow catalog (✅ Phases 1+2 complete). Core caches it, filters by scope intersection, and registers each workflow as a normal LLM tool bound to a single generic `WorkflowEngineHandler`. Workflows declare a `coreDirectives` array (`#require("approval")`, `#preValidation([...])`) that Core acts on before dispatch. The agent never sees `dispatch_workflow`, permits, or envelopes.

**Phase B — WorkflowEngineHandler & dynamic tool registration** _(depends on Phase A/0 — OperationPermit retired, all handlers return ToolCallOutcome)_

**Goal**

Replace the static `dispatch_workflow` tool with per-workflow tools dynamically built from the catalog. Each descriptor is bound to a single `WorkflowEngineHandler.handle()` closure; `coreDirectives` are acted on by Core before any dispatch.

**Current State**

- `dispatch-workflow-handler.mo` exists: returns `ToolCallOutcome`, handles catalog hash + stale retry, uses static `dispatch_workflow` tool.
- `function-tool-registry.mo` registers one static `dispatch_workflow` tool.
- `admin-agent-loop.mo` has unused `_triggerMessageText` and `_resolveWorkspaceName` params.
- `types/execution.mo`: `EnvelopePayload` has `workflowId : Text` (to be renamed).

**Desired State**

- New `workflow-engine-handler.mo` drives all workflow dispatch from descriptors.
- One `FunctionTool` per permitted descriptor, built dynamically by `function-tool-registry.mo`.
- Catalog eagerly pre-loaded per turn if cache is null.
- `EnvelopePayload.workflowName` (renamed from `workflowId`).
- `dispatch-workflow-handler.mo` deleted.
- `_triggerMessageText` and `_resolveWorkspaceName` removed from `AdminAgentLoop.process()` signature.

**Source Steps**

B.0 — Rename `workflowId` → `workflowName` in `EnvelopePayload`:

- `src/control-plane-core/types/execution.mo`: field rename.
- `src/internal-engine/execution-types.mo`: field rename; update engine runner usage.
- Test fixtures: update `workflowId` references.

B.1 — Create `src/control-plane-core/agents/tools/handlers/workflow-engine-handler.mo`:

- Type aliases: `EngineDispatch`, `EnvelopeContext` — matching `ToolResources` inline record shapes.
- `buildScopeGrants(agent) : [ScopeGrant]` — **public**; verbatim copy from `dispatch-workflow-handler.mo`.
- `handle(descriptor, engineDispatch, envelopeContext, resolveSlackBotToken, args) : async ToolCallOutcome`:
  1. Parse `args` JSON → `#error(msg)` on invalid JSON.
  2. Scan `descriptor.coreDirectives` (synchronous; no awaits before this):
     - `#require("approval")`: if `"approvalCode"` absent in args → `#error("This workflow requires user approval. ...")` _(interim — Phase C replaces with real approval initiation)_.
     - `#preValidation(rules)`: for each `"slack_channel_exists"` rule → extract param from args → resolve bot token → await `SlackWrapper.getChannelInfo` → `#error(msg)` on failure. Unknown rules silently skipped.
  3. Catalog hash: lazy refresh if null; `#error(msg)` if still null.
  4. `ExecutionEnvelopeModel.issue(...)`.
  5. Build `EnvelopePayload` with `workflowName = descriptor.workflowName`.
  6. `EngineDispatchService.dispatch()`:
     - `#ok` → `#success("{\"dispatched\":true}")`.
     - `#err` with `"staleCatalog"` in JSON → refresh + revoke envelope → `#error("Workflow catalog was updated. Please retry.")`.
     - Other `#err` → revoke envelope → `#error(msg)`.
  7. `catch Error` → revoke envelope → `#error("Engine call failed: " # Error.message(e))`.

B.2 — Update `function-tool-registry.mo`:

- Remove `DispatchWorkflowHandler` import; add `WorkflowEngineHandler`, `WorkflowCatalogService`.
- Replace static `dispatch_workflow` block with dynamic loop over `filterByScopes(descriptors, WorkflowEngineHandler.buildScopeGrants(agent))`.
- Per descriptor: `FunctionTool` with `name = workflowName`, `description`, `parameters = ?parametersJsonSchema` (direct pass-through — `FunctionDef.parameters : ?Text`). Handler closure → `await WorkflowEngineHandler.handle(descriptor, ...)`.

B.3 — Update `admin-agent-loop.mo`:

- Eager catalog pre-load at `process()` start: if `engineDeps.catalogState.cached == null`, `ignore await WorkflowCatalogService.refreshCatalogue(...)`.
- Remove `_triggerMessageText : ?Text` and `_resolveWorkspaceName : (Nat -> ?Text)` from signature.

B.4 — Update `agent-orchestrator.mo` + `test-canister.mo`:

- Remove the two dropped args from `AdminAgentLoop.process(...)` call sites.
- Prefix `workspaces` as `_workspaces` (full removal deferred).

B.5 — Delete `dispatch-workflow-handler.mo`:

- Confirm no remaining imports; delete file.

**Test Steps**

- `icp build control-plane-core` + `bun run test:build` clean after B.0.
- `icp build control-plane-core` clean after B.1–B.5.
- New unit tests `workflow-engine-handler.test.mo`: `buildScopeGrants` for org-admin (4 grants), non-org-admin (3 grants), `#custom` (1 grant).
- `mops test` — all pass.
- `bun run tsc --noEmit` + `bun run format` before commit.

---

**Phase C.a — Dispatch-Resume** _(depends on Phase B)_

**Goal**

Replace the current dispatch-and-terminate behavior: when the admin loop dispatches a workflow it now _suspends_ with a checkpoint. When the engine posts `executionComplete`, the loop resumes as a continuation of the same LLM conversation, with the full engine result injected as the tool result so the LLM can reason about next steps.

**Current State**

- `adminLoop` detects `dispatched:true` in tool results → returns `#dispatched`.
- `message-handler.mo` marks the turn `#pending`.
- `ExecutionAsyncEffectService.processEffect()` on `#complete` → posts `humanSummary` to Slack, marks turn `#succeeded`. Turn ends; no LLM continuation.

**Desired State**

- When `adminLoop` detects the dispatch signal it captures `SuspensionData` and returns `#dispatched { suspension }`.
- `message-handler.mo` sets `turn.status := #awaitingWorkflow(suspension)` (no separate model function; status is the checkpoint).
- `ExecutionAsyncEffectService.processEffect()` on `#complete`:
  - Pattern-match `turn.status`: `case (#awaitingWorkflow(suspension))`: build synthetic tool result JSON → call `resumeAdminTurn` closure → handle result (post to Slack + complete turn on `#ok`/`#err`).
  - All other statuses: current behavior (post `humanSummary`, mark `#succeeded`).
- `AdminAgentLoop.process()` accepts an optional `resumeOverride : ?{ messages : [ResponseInputMessage]; startRound : Nat }`. If provided, skip `ContextAssembler` and use those messages, starting the loop counter at `startRound`. If null, normal context assembly at round 0.

**Synthetic tool result JSON** (injected at resume, keyed by `pendingToolCallId`):

```json
{
  "status": "completed | failed | roundLimitReached",
  "humanSummary": "...",
  "stepsDetail": [{ "tool": "...", "summary": "...", "success": true }],
  "stats": { "durationNs": ..., "llmCalls": ..., "inputTokens": ..., "outputTokens": ..., "estimatedDollarCost": ... }
}
```

**New types**

```motoko
// session-model.mo
public type SuspensionData = {
  messages : [OpenRouterWrapper.ResponseInputMessage]; // full accumulated message history at suspension
  pendingToolCallId : Text; // call ID of the dispatching tool call (needed because a round may have multiple tool calls, only one of which dispatched the workflow)
  roundCount : Nat; // loop counter at suspension — enforces MAX_AGENT_ROUNDS across the resume boundary
};

// TurnStatus: bare #pending removed; suspension data lives in var status directly.
public type TurnStatus = {
  #running;
  #awaitingWorkflow : SuspensionData; // dispatched to engine; C.b adds #awaitingApproval
  #succeeded;
  #failed;
};

```

`AgentTurnRecord`: **no new field**. `var status` already carries the suspension data inside `#awaitingWorkflow`. `ResumeMode` type is not introduced — it's encoded in the `TurnStatus` variant itself.

`AgentOrchestrateResult.#dispatched` is extended:

```motoko
#dispatched : { steps : [ProcessingStep]; suspension : SuspensionData };

```

**Source Steps**

C.a.1 — `session-model.mo`: add `SuspensionData` type; replace bare `#pending` in `TurnStatus` with `#awaitingWorkflow : SuspensionData`. No new field on `AgentTurnRecord`; no checkpoint helper functions.

C.a.2 — `types.mo`: extend `AgentOrchestrateResult.#dispatched` with `suspension : SuspensionData`.

C.a.3 — `admin-agent-loop.mo`:

- `process()` signature: add `resumeOverride : ?{ messages : [ResponseInputMessage]; startRound : Nat }`. If provided, skip `ContextAssembler`, use those messages + `startRound`.
- `adminLoop`: when dispatch signal detected, build `SuspensionData { messages = List.toArray(inputHistory); pendingToolCallId = <callId of the dispatching ToolCall>; roundCount = rounds }`. Return `#dispatched { steps; suspension }`.

C.a.4 — `message-handler.mo`: on `#dispatched { suspension }` → `turn.status := #awaitingWorkflow(suspension)`. No separate model function call; the status itself is the checkpoint.

C.a.5 — `execution-async-effect-service.mo`:

- `ServiceDeps` gets `resumeAdminTurn : (turnId : Text, syntheticResult : Text) -> async Types.AgentOrchestrateResult`.
- In `processEffect` for `#complete`: pattern-match `turn.status` — `case (#awaitingWorkflow(suspension))`: build synthetic tool result JSON from `humanSummary`, `stepsDetail`, `status`, `stats`; call `deps.resumeAdminTurn(turnId, syntheticResult)`; handle result (post to Slack + complete turn on `#ok`/`#err`, post error + `#failed` on `#err`). All other statuses: current behavior (post `humanSummary`, mark `#succeeded`).

C.a.6 — `agent-orchestrator.mo`: thread `sessionStores` into `AdminAgentLoop.process(...)` call; pass `resumeOverride = null` (fresh start always from orchestrator).

C.a.7 — `main.mo`: build `resumeAdminTurn` closure capturing all stable state; inject into `executionAsyncEffectService`. The closure: looks up agent + turn, pattern-matches `turn.status` to extract `suspension`, derives API key + workspace key, constructs `resumeOverride = ?{ messages = suspension.messages ++ [syntheticToolResultMsg]; startRound = suspension.roundCount }`, calls `AdminAgentLoop.process(...)`.

**Test Steps**

- `icp build control-plane-core` clean after C.a.1–C.a.7.
- Unit test `session-model`: `TurnStatus` round-trip with `#awaitingWorkflow(SuspensionData)` — set and read back via `turn.status`.
- Unit test `admin-agent-loop` (mock engine): dispatch → `#dispatched { suspension }` where `suspension` carries correct `messages`, `pendingToolCallId`, `roundCount = 1`.
- Integration test: dispatch workflow → engine completes → admin loop resumes → LLM generates final response → `#succeeded`. Verify `stepsDetail` appears in synthetic tool result passed to the LLM.
- `mops test` — all pass. `bun run tsc --noEmit` + `bun run format` before commit.

---

~~**Phase C.b — Approval Gate** _(depends on Phase C.a)_ ✅ COMPLETE~~

**Goal**

When a workflow has `#require("approval")` in `coreDirectives` and the agent calls it without an approval code, the handler suspends the turn (posting an approval prompt to Slack), the agent waits, and the original requester can approve it by replying `approve <code>` in the thread. On approval, the workflow is re-dispatched transparently and the LLM continues as if dispatch was immediate.

**UX**: Text-reply only in this phase (`approve <64-char-hex>`). Block Kit buttons and expired-button UX are deferred to 5.2.1.1.

**Implemented State**

- `WorkflowEngineHandler.handle()` — replace interim stub for `#require("approval")` without `approvalCode`:
  1. Call `ApprovalModel.request(approvalState, ...)` → returns a 64-char hex code.
  2. Build `renderedArgs` = pretty-printed JSON of the tool args (all fields, indented).
  3. Post Slack text message to the turn's channel + thread: `"Workflow \`<workflowName>\` requires approval.\nArguments:\n\`\`\`<renderedArgs>\`\`\`\nReply with \`approve <code>\` to proceed.\nApproval code: \`<code>\`"`.
  4. Return `#ok("{\"dispatched\":false,\"approvalRequired\":true,\"approvalCode\":\"<code>\"}")`.
- `WorkflowEngineHandler.handle()` with an `approvalCode` now accepts only a code already consumed by `ApprovalModel.validate(...)` and correlated to the same turn, workflow, agent, workspace, and requester.
- `adminLoop` detects `approvalRequired:true` signal → captures `SuspensionData` and returns `#awaitingApproval { suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId }`.
- `message-handler.mo` on `#awaitingApproval`: sets `turn.status := #awaitingApproval({ suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId })` directly.
- `MessageHandler.handle()` pre-agent interception (after round context, before new turn creation): if message text matches `approve\s+([a-f0-9]{64})` (case-insensitive, trimmed, with or without `::agentname` prefix stripped):
  - Calls `ApprovalModel.validate(...)` to verify the code is pending and belongs to the requester; on success the code is marked `#used` before any await.
  - Delegates to `ApprovalDispatchService.dispatchApproved(...)`.
  - Non-approval messages: normal flow (no change).
- `ApprovalDispatchService.dispatchApproved(...)` is intentionally narrow:
  1. Look up the suspended turn and verify it is still `#awaitingApproval`.
  2. Verify the consumed approval record matches the suspended workflow metadata.
  3. Inject `approvalCode` into the original tool args.
  4. Call `WorkflowEngineHandler.handle(...)` to reuse catalog checks, pre-validation, envelope issuance, and engine dispatch.
  5. On `dispatched:true`, set `turn.status := #awaitingWorkflow(suspension)`.
  6. It does **not** resume the LLM. The existing `ExecutionAsyncEffectService` resumes the LLM only when the engine sends the real workflow completion result.

**New types**

```motoko
// session-model.mo — extend TurnStatus (C.b adds the #awaitingApproval variant)
// No ResumeMode type; the variant itself encodes the mode.
public type TurnStatus = {
  #running;
  #awaitingWorkflow : SuspensionData; // dispatched to engine (from C.a)
  #awaitingApproval : {
    // waiting for human approval
    suspension : SuspensionData; // common resume fields (messages, pendingToolCallId, roundCount)
    workflowName : Text;
    approvalCode : Text;
    originalToolArgs : Text; // exact JSON args the LLM passed (do not normalize)
    requestedByUserId : Text;
  };
  #succeeded;
  #failed;
};

// approval-model.mo (new file)
public type ApprovalStatus = { #pending; #used; #expired };

public type ApprovalRecord = {
  code : Text;
  workflowName : Text;
  renderedArgs : Text;
  workspaceId : Nat;
  agentId : Nat;
  turnId : Text;
  requestedByUserId : Text;
  requestedAt : Int;
  var status : ApprovalStatus;
};

public type ApprovalState = {
  var counter : Nat;
  var approvalSalt : Blob;
  approvals : Map.Map<Text, ApprovalRecord>; // keyed by code
};

```

Model functions (state parameter first per Motoko conventions):

- `request(state, workflowName, renderedArgs, workspaceId, agentId, turnId, requestedByUserId) : Text` — generates code via `makeNonce(state.approvalSalt, state.counter, now)`, creates record, increments counter, returns code.
- `findByCode(state, code) : ?ApprovalRecord` — lookup.
- `validate(state, code, requestedByUserId) : Result<ApprovalRecord, Text>` — checks record exists, status is `#pending`, userId matches → marks `#used`, returns record.
- `expire(state, code)` — marks `#expired` (called by TTL timer in 5.2.1.1).

`AgentOrchestrateResult` gains:

```motoko
#awaitingApproval : {
  steps : [ProcessingStep];
  suspension : SuspensionData;
  workflowName : Text;
  approvalCode : Text;
  originalToolArgs : Text;
  requestedByUserId : Text;
};

```

**`ToolResources.engineDispatch`** gets `approvalState : ApprovalModel.ApprovalState`.

`EventProcessingContext` gets `approvalState : ApprovalModel.ApprovalState`.

`WorkflowEngineHandler.handle()` signature: add `approvalState : ApprovalModel.ApprovalState` and `slackChannelId : Text` + `slackThreadTs : ?Text` (for posting the approval message). These come from `ToolResources.envelopeContext` (add fields there) and `ToolResources.engineDispatch`.

**Source Steps**

C.b.1 — New `models/approval-model.mo`: `ApprovalState`, `ApprovalRecord`, `ApprovalStatus` types; `request`, `findByCode`, `validate`, `expire` functions.

C.b.2 — `session-model.mo`: add `#awaitingApproval { suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId }` variant to `TurnStatus`. No `markAwaitingApproval` model function — message-handler sets `turn.status` directly.

C.b.3 — `types.mo`: add `#awaitingApproval : { steps; suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId }` to `AgentOrchestrateResult`.

C.b.4 — `tool-types.mo`: add `approvalState : ApprovalModel.ApprovalState` to `ToolResources.engineDispatch`; add `slackChannelId : Text` + `slackThreadTs : ?Text` to `EnvelopeContext`.

C.b.5 — `workflow-engine-handler.mo`: replace interim `#require("approval")` stub with the real flow: `ApprovalModel.request()`, build `renderedArgs` (JSON pretty-print), post Slack message, return `#ok({dispatched:false, approvalRequired:true, approvalCode})`.

C.b.6 — `admin-agent-loop.mo`: detect `approvalRequired:true` signal; capture `SuspensionData { messages; pendingToolCallId; roundCount }`; return `#awaitingApproval { steps; suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId }`. Also: thread `approvalState` through `ToolResources.engineDispatch` and `slackChannelId`/`slackThreadTs` through `EnvelopeContext`.

C.b.7 — `message-handler.mo`:

- Handle `#awaitingApproval` result: `turn.status := #awaitingApproval({ suspension; workflowName; approvalCode; originalToolArgs; requestedByUserId })`.
- Add `approve <code>` interception (before new turn creation): parse, `ApprovalModel.findByCode`, user check, `ApprovalModel.validate`, call `resumeApprovalTurn`.
- Add private `resumeApprovalTurn` helper (steps described in Desired State above).

C.b.8 — `events/types/event-processing-context.mo`: add `approvalState : ApprovalModel.ApprovalState`.

C.b.9 — `main.mo`: add `approvalState : ApprovalModel.ApprovalState` to persistent state (with `approvalSalt` refreshed on upgrade via `raw_rand`, same pattern as `envelopeSalt`); wire `approvalState` into `EventProcessingContext` and `executionAsyncEffectService` deps.

C.b.10 — `agent-orchestrator.mo` + `admin-agent-loop.mo`: thread `approvalState`, `slackChannelId`, `slackThreadTs` into `process()`.

**Test Steps**

- `icp build control-plane-core` clean after each step.
- Unit test `approval-model`: `request` → `findByCode` round-trip. `validate` happy path → marks `#used`. `validate` wrong userId → error. `validate` already `#used` code → error. `expire` → marks `#expired`. `validate` expired code → error.
- Unit test `workflow-engine-handler` (mock Slack + ApprovalModel): `#require("approval")`, no code → `#ok({approvalRequired:true, approvalCode})` + Slack message posted. `#require("approval")`, valid code + valid `ApprovalModel.validate` → proceeds to dispatch.
- Unit test `admin-agent-loop` (mock handler): approval signal → `#awaitingApproval` carrying `SuspensionData` with correct `messages`, `pendingToolCallId`, `roundCount`. Dispatch following approval resume → `#dispatched`.
- Unit test `message-handler` (approve interception): valid `approve <code>` from correct user → `resumeApprovalTurn` called. Valid code but wrong user → error posted, no turn created. Invalid/used code → error posted, no turn created. Non-approval message → normal turn flow.
- `mops test` — all pass. `bun run tsc --noEmit` + `bun run format` before commit.

---

### 5.2.1.1 — Approval TTL: per-turn timers, Block Kit, cancellable, upgrade-recovered _(depends on Phase C.b)_

**Goal**

Harden the approval gate with a 1-hour TTL (per-turn cancellable timer, recovered after upgrade), interactive Block Kit buttons (Approve / Deny) replacing the plain-text prompt, HMAC verification applied to interactive payloads (event callbacks already verified), and a denial path that resumes the LLM with a denial signal so it can acknowledge and react.

**Current State**

- `WorkflowEngineHandler.handle()` posts a plain-text Slack message with the code and `approve <code>` instructions.
- Approval interception is text-only (`approve <code>` in a Slack reply); no button-based path.
- `TurnStatus.#awaitingApproval` has no TTL, no `timerId`.
- `ApprovalRecord` has no `expiresAtNs`.
- No per-turn cancellable timer; no `postupgrade` recovery for pending approvals.
- `http_request_update` handles `event_callback` and `url_verification` only; HMAC is already applied to event callbacks via `SlackAdapter.verifySignature`. No `block_actions` routing exists.
- `AgentRunner` has `resumeWithApproval` but no `resumeWithDenial`.
- `SlackWrapper.postMessage` accepts `text : Text` only; no `blocks` parameter.
- `SlackAdapter.parseEnvelope` handles JSON bodies only; not URL-encoded `payload=...` bodies.

**Desired State**

- `APPROVAL_TTL_NS : Int = 3_600_000_000_000` in `constants.mo`.
- `ApprovalRecord.expiresAtNs : Int` set to `requestedAt + APPROVAL_TTL_NS` inside `request()`.
- `TurnStatus.#awaitingApproval` carries two new fields: `expiresAtNs : Int` and `var timerId : ?Timer.TimerId`.
- Approval prompt posted as a Block Kit message (section block with workflow name, rendered args, and text-fallback `approve <code>` instructions; actions block with `Approve` (primary) and `Deny` (danger) buttons, both with `value = approvalCode`). Text-reply path (`approve <code>` in `message-handler.mo`) is preserved alongside buttons.
- Per-turn one-shot timer armed when turn enters `#awaitingApproval`. `timerId` stored in `turn.status`.
- Timer cancellation before any status transition (button click or text-reply approval, denial, or expiry race guard).
- Timer fire: re-check `turn.status` under guard; if still `#awaitingApproval` → run denial path (resume LLM with `{denied:true, reason:"approval timed out"}`), post thread message "Approval request expired.". If status already changed, no-op.
- `block_actions` routing in `http_request_update`. Interactive payloads hit the same canister URL as event callbacks; differentiated by body format (`payload=<url-encoded-json>` vs JSON). HMAC applied to both.
- New `BlockActionsHandler` handles `approve_workflow` and `deny_workflow` actions:
  - Actor check: `slackUserId == approval.requestedByUserId` OR `Set.contains(userAuthCtx.adminWorkspaces, agent.ownedBy)`. Note: workspace admins (of the agent's owning workspace), not org admins.
  - Approve: `ApprovalModel.validate` (marks `#used` synchronously), cancel timer, fire-and-forget `resumeWithApproval`. Returns `{"replace_original":true,"text":"✅ Approved by <userId>."}` in HTTP response.
  - Deny: `ApprovalModel.expire`, cancel timer, fire-and-forget `resumeWithDenial("user denied")`. Returns `{"replace_original":true,"text":"🚫 Denied by <userId>."}` in HTTP response.
  - Already-used/expired code → returns "This approval request has already been processed." (no state change).
  - Unauthorized actor → returns "You are not authorized to approve or deny this workflow." (no state change).
- `AgentRunner.resumeWithDenial`: builds synthetic tool result `{dispatched:false,denied:true,reason:<reason>}`, splices into suspension messages at `pendingToolCallId`, resumes `AdminAgentLoop.process()`.
- `postupgrade` recovery: in `main.mo`'s `timerRegistry()`, scan all `#awaitingApproval` turns, re-arm one-shot timer at `expiresAtNs` (zero-delay if past), overwrite stale `timerId` in `turn.status`.

**New / modified types**

```motoko
// constants.mo
APPROVAL_TTL_NS : Int = 3_600_000_000_000; // 1 hour

// approval-model.mo — ApprovalRecord gains:
expiresAtNs : Int; // set in request() as requestedAt + APPROVAL_TTL_NS

// session-model.mo — TurnStatus.#awaitingApproval gains:
expiresAtNs : Int;
var timerId : ?Timer.TimerId;

```

**Source Steps**

1. **`constants.mo`**: Add `APPROVAL_TTL_NS : Int = 3_600_000_000_000`.

2. **`approval-model.mo`**: Add `expiresAtNs : Int` to `ApprovalRecord`. In `request()`, set `expiresAtNs = requestedAt + Constants.APPROVAL_TTL_NS`.

3. **`session-model.mo`**: Add `expiresAtNs : Int` and `var timerId : ?Timer.TimerId` to the record inside `#awaitingApproval`. Update every pattern-match and construction site.

4. **`agent-runner.mo`**: Add `resumeWithDenial(deps, keyCache, suspension, turnId, reason, botTokenOpt) : async DispatchResult`:
   - Guard: turn must be `#awaitingApproval`.
   - Build synthetic tool result JSON: `{dispatched:false,denied:true,reason:reason}` for `suspension.pendingToolCallId`.
   - Mark turn `#running`. Resume `AdminAgentLoop.process(...)` with `resumeOverride = ?{messages = suspension.messages ++ [toolResultMsg]; startRound = suspension.roundCount}`.
   - On `#ok`/`#error`: complete turn, post to Slack. Caller is responsible for cancelling the timer before calling this.

5. **New `timers/approval-timer.mo`**:
   - `arm(expiresAtNs : Int, callback : () -> async ()) : Timer.TimerId` — computes `delay = max(0, expiresAtNs - Time.now())`, calls `Timer.setTimer(#nanoseconds(delay), callback)`, returns `TimerId`.
   - `cancel(timerId : Timer.TimerId)` — calls `Timer.cancelTimer(timerId)` (no-op if already fired).

6. **`slack-wrapper.mo`**: Add optional `blocks : ?Text` parameter to `postMessage`. When non-null, serialize the `blocks` JSON array in the request body alongside (or replacing) `text`.

7. **`workflow-engine-handler.mo`**: Replace plain-text Slack message with Block Kit message. Build blocks JSON containing a section block (workflow name, rendered args, `approve <code>` text fallback) and an actions block (Approve primary button, Deny danger button; both `value = approvalCode`). Call `SlackWrapper.postMessage` with the `blocks` param. No other changes to the return value.

8. **`message-handler.mo`**:
   - On `#awaitingApproval` result: look up `expiresAtNs` from `ApprovalModel.findByCode(approvalState, approvalCode)`, set `turn.status := #awaitingApproval({..., expiresAtNs, timerId = null})`, arm timer via `ApprovalTimer.arm(expiresAtNs, onExpire)` where `onExpire` is a closure calling `AgentRunner.resumeWithDenial(...)`, then set `turn.status.timerId := ?timerId`.
   - In text-reply approval interception path (before `AgentRunner.resumeWithApproval`): extract `timerId` from `turn.status.#awaitingApproval` and call `ApprovalTimer.cancel(timerId)`.

9. **`slack-adapter.mo`** (or `wrappers/slack-adapter.mo`): Extend `parseEnvelope` to detect a `payload=` prefix on the body. Percent-decode the value, parse as JSON, check `"type":"block_actions"`, and return a new `#block_actions : BlockActionsPayload` variant. Add `BlockActionsPayload` type: `{ userId : Text; workspaceId : Text; actionId : Text; actionValue : Text; messageTs : Text; channelId : Text }` (extracted from the nested interactive payload JSON).

10. **New `events/handlers/block-actions-handler.mo`**:
    - `handle(payload : SlackAdapter.BlockActionsPayload, deps : BlockActionsDeps) : async Text` (returns message-update JSON string for HTTP response body).
    - Guard: `actionId` must be `approve_workflow` or `deny_workflow`; otherwise return `""`.
    - Look up approval record by `actionValue` (the approval code). Not found → return error text.
    - If `status != #pending` → return "This approval request has already been processed."
    - Actor check: `payload.userId == approval.requestedByUserId` OR `Set.contains(SlackAuthMiddleware.buildFromCache(slackUsers, payload.userId).adminWorkspaces, agent.ownedBy)`. Fail → return "You are not authorized...".
    - `approve_workflow`: `ApprovalModel.validate` (sync), cancel timer, `ignore Timer.setTimer(#nanoseconds(0), approvalResumeCb)`. Return `{"replace_original":true,"text":"✅ Approved by <userId>."}`.
    - `deny_workflow`: `ApprovalModel.expire` (sync), cancel timer, `ignore Timer.setTimer(#nanoseconds(0), denialResumeCb)` with reason `"user denied"`. Return `{"replace_original":true,"text":"🚫 Denied by <userId>."}`.

11. **`main.mo`**:
    - `http_request_update`: after `SlackAdapter.parseEnvelope`, add `#block_actions` branch. The existing HMAC check already covers it (happens after the parse branch). Route to `BlockActionsHandler.handle(...)`; return 200 with `Content-Type: application/json` and message-update JSON body.
    - `timerRegistry()` (or a zero-delay `postupgrade` timer): iterate all turns via `SessionModel`; for each `#awaitingApproval(data)` turn, call `ApprovalTimer.arm(data.expiresAtNs, onExpire)` with a closure built from the turn ID, and set `data.timerId := ?newTimerId`. This overwrites stale pre-upgrade `timerId`s.

**Test Steps**

- `icp build control-plane-core` clean after each step.
- Unit test `approval-model`: `request()` sets `expiresAtNs = requestedAt + APPROVAL_TTL_NS`.
- Unit test `approval-timer`: `arm` with future deadline returns `TimerId`. `arm` with past deadline uses zero-delay (still returns `TimerId`). `cancel` is a no-op after firing.
- Unit test `session-model`: `#awaitingApproval` round-trip with `expiresAtNs` and `var timerId`; `timerId` mutates in place via pattern-match binding.
- Unit test `agent-runner` (mock loop): `resumeWithDenial` injects `{denied:true, reason:"..."}` tool result, loop resumes, turn marked complete.
- Unit test `block-actions-handler`:
  - `approve_workflow` from original requester → `#used`, timer cancelled, approve resume scheduled, returns "replace_original" JSON.
  - `deny_workflow` from workspace admin of `agent.ownedBy` → denial resume scheduled.
  - Org admin (not workspace admin) → unauthorized error.
  - Already-used code → "already processed" response, no state change.
  - Unknown `actionId` → returns `""` (ignored).
- Unit test `slack-adapter`: body `payload=<url-encoded-json>` → parses to `#block_actions` with correct `userId`, `actionId`, `actionValue`.
- Integration test: approval workflow → Block Kit message posted with Approve/Deny buttons. `block_actions` payload with `approve_workflow` → `resumeWithApproval` fires → turn completes. `block_actions` with `deny_workflow` → `resumeWithDenial` fires → LLM acknowledges denial. Short-TTL integration test → timer fires → denial with "approval timed out" reason → LLM resumes. Text-reply `approve <code>` still works alongside buttons.
- `mops test` — all pass. `bun run tsc --noEmit` + `bun run format` before commit.

---

**Decisions locked**

- Per-capability workflows; no `admin-v1` umbrella.
- `workflowName` is the public identifier everywhere, including `EnvelopePayload` (renamed from `workflowId` in Phase B).
- `coreDirectives : [CoreDirective]` — non-nullable array. Recognized today: `#require("approval")`, `#preValidation([...])`. Unknown variants silently ignored.
- Catalog hash = SHA-256 over canonical JSON. No manual version bumping.
- Hash handshake only on `execute()`; mismatch → refresh → `#err` → LLM retries with fresh tool list.
- `#require("approval")` is the approval gate — lives in `coreDirectives`. No separate `requiresApproval` field on descriptor.
- Approval code = `makeNonce(approvalSalt, approvalCounter, now)` — same algorithm as envelope nonce, separate salt + counter.
- `#err(text)` in `ToolCallOutcome` → structured JSON `{"type":"camelCase","message":"..."}`, never plain string. `#ok(text)` → meaningful result data, no redundant `"success": true`. Variant names are `#ok`/`#err` (not `#success`/`#error`) to align with the ICP `Result` pattern.
- Approval interception: parse `approve <code>` (case-insensitive, with or without `::agentname` prefix stripped) → look up code in `ApprovalModel` by code → no secondary index needed, the record carries `turnId` + `requestedByUserId`.
- Wrong code from correct user → post error, keep turn `#awaitingApproval`.
- Different user sends approval message → post error, consume message, no new turn created.
- Block Kit buttons deferred to 5.2.1.1; Phase C.b is text-reply only (`approve <64-char-hex>`).
- Per-turn cancellable timers (TTL), recovered in `postupgrade` — deferred to 5.2.1.1.
- No separate `resume()` entry point; `AdminAgentLoop.process()` accepts `resumeOverride : ?{ messages; startRound }` — null for fresh start, set for both dispatch-resume and approval-resume.
- Same-turn resume; single in-flight workflow per turn.
- Dispatch-resume always fires: engine result is always injected as a tool result and the loop continues; the LLM decides the next step.
- `renderedArgs` in `ApprovalRecord` is pretty-printed JSON of the tool args (deterministic, no extra LLM call).
- Approval-resume is transparent to the LLM: the approval interlude does not appear in the message history. The LLM sees the original tool call followed by `{dispatched: true}` (from the re-executed handler after approval), then the engine result on C.a resume.
- `SuspensionData` carries `messages`, `pendingToolCallId`, and `roundCount`. Messages are not reconstructible from the trace (the trace is observability data, not an LLM replay log). `pendingToolCallId` is not derivable from messages because a round may contain multiple tool calls. `roundCount` is kept explicit to correctly enforce `MAX_AGENT_ROUNDS` across the resume boundary.
- `TurnStatus` encodes suspension data directly in its variants (`#awaitingWorkflow : SuspensionData`, `#awaitingApproval : { suspension; ... }`). No separate `ResumeMode` type; no `pendingResume` field on `AgentTurnRecord`.

**Future considerations — batch dispatch**

- **Wait-all** (LLM emits N tool calls; turn resumes when all complete): cheap parallelism, head-of-line blocking, awkward partial-failure UX. Requires a barrier counter in `TurnStatus`.
- **Wait-any with `await_workflow` tool**: max flexibility, multi-suspension lifecycle, orphaned-envelope GC, new prompting idiom.
- Common pre requests: `TurnStatus` becomes a barrier; engine emits stable `envelopeId` in completion; Slack UX handles interleaved progress.
- Approval × batch: bundled approvals or fail-fast on first denial. Ship single-dispatch first.

**Risks**

- `coreDirectives` parsing must tolerate unknown variants (forward compat).
- `#awaitingWorkflow` and `#awaitingApproval` are new `TurnStatus` variants — no stable migration needed since nothing is in production. The bare `#pending` variant is removed.
- `approvalSalt` in `ApprovalState` must be seeded (same `raw_rand` pattern as `envelopeSalt`); zero salt weakens nonce unpredictability.
- Approval-resume re-executes the handler synchronously in `MessageHandler` — if the engine dispatch itself fails, the turn must be marked `#failed` with a user-visible error.
- Catalog may be stale at approval-resume time: the handler re-uses the catalog in `ctx.catalogState`; if the catalog was invalidated between the original call and the approval, the handler returns `#err(staleCatalog)` and the turn must be marked `#failed` (user must retry from scratch).
- `originalToolArgs` in `#awaitingApproval` must be the exact JSON string the LLM passed; do not normalize or re-serialize to avoid breaking the handler's arg parsing.
- `approvalCode` unpredictability relies on nonce construction; never use sequential IDs.

---

#### Comment for batch addressing

- src/internal-engine/tools/tool-executor.mo
  `for (call in toolCalls.vals()) {`
  [External deep review] Medium severity: tool batch execution is strictly sequential (await each call). Independent tool calls per round could run concurrently and then be joined, preserving callId mapping while reducing latency.

---

### 5.2.2.1 - Review Execution naming, consider Workflow

In a previous refactor, have changed from "Execution" (Engine) concept to "Workflow" (Engine) concept.

But am realizing some sibling concepts are still to be renamed, like ExecutionEnvelope, should be WorkflowEnvelope : "src/control-plane-core/models/execution-envelope-model.mo".

Instead of ExecutionAPI it should be workflowAPI (endpoint and service), etc...

### 5.2.2 - Improve the EnvelopePayload to more sensible fields

- model in secrets?
- workflow params
- catalog version
- overall review

### 5.2.3 — HMAC encrypted envelop (JSON format always)

- on core, generate a private key for the engine and submit it through an inter canister call.
- on engine, store the secret and ensure request is coming from the owner.
- when envelope is generated, it converts to JSON, and then is encrypted in HMAC and sent on the execute call (both the signature and the body).
- Engine decrypts the body, then parses it to Candid, then proceeds as usual.

---

### 5.3 — Filesystem: Data Model + Admin Tools

**Goal**

Introduce the Filesystem — a file-like key-value persistence layer for structured and unstructured agent knowledge, scoped per agent. Each agent owns its own fully isolated filesystem; no agent can read or write another agent's filesystem. This phase builds the data model and wires infrastructure so agents can manage their own filesystem entries at runtime. Agent-facing tools (`file_read`, `file_write`, `delete_file_entry`) come in 5.4.

**Current State**

- No filesystem model exists. ARCHITECTURE.md specifies it as a `[planned]` concept.
- Agents have no persistent knowledge storage beyond session traces and channel history.
- `ToolResources` in `tool-types.mo` has no filesystem resource.
- Skill documents are planned as filesystem entries under `/skills/` paths but do not exist yet.

**Desired State**

- New `models/filesystem-model.mo` module with the following data types and operations:

  ```motoko
  public type FileEntry = {
    path : Text; // absolute path, e.g. "/skills/create-spec/SKILL.md"
    name : Text; // filename, e.g. "SKILL.md"
    extension : Text; // e.g. "md", "json", "txt"
    description : Text; // LLM guidance: purpose, update cadence, interaction rules
    content : Text; // the file content
    createdAt : Int; // timestamp (nanoseconds)
    updatedAt : Int; // timestamp (nanoseconds)
  };

  ```

- Filesystem state: `FilesystemState = Map<Text, FileEntry>` keyed by `path`. Each agent holds its own `FilesystemState` instance — there is never a shared map across agents. All paths must be absolute and valid: must start with `/`, must not contain `..` segments, must not contain consecutive `/` characters, and must not end with `/` (trailing slash is reserved for directory-listing queries, not file paths). The model rejects any path that fails these rules (no silent normalization for invalid paths).
- Persistent global state in `main.mo`: `Map<Nat, FilesystemModel.FilesystemState>` keyed by agent ID. Each agent's `FilesystemState` is fetched by agent ID and passed as a resource; agents never see each other's instances.
- Model functions (state parameter first, per Motoko conventions):
  - `create(state, entry) → Result<FileEntry, Text>` — creates a new entry. Fails if path already exists (use `update` for overwrites). Validates path format.
  - `update(state, path, entry) → Result<FileEntry, Text>` — updates an existing entry. Fails if path doesn't exist (use `create` for new files). Validates path format.
  - `get(state, path) → ?FileEntry` — retrieves a single entry by exact path.
  - `delete(state, path) → Result<FileEntry, Text>` — removes an entry, returns the deleted entry.
  - `list(state, pathPrefix) → [FileEntry]` — lists all entries whose path starts with `pathPrefix`. The prefix must end with `/` (e.g. `/skills/`) to avoid boundary ambiguity — `/skill/` will not match `/skills/foo.md`. Passing `/` returns all entries. Rejects prefixes that don't end with `/`.
  - `listPaths(state, pathPrefix) → [Text]` — lightweight variant returning only paths (same prefix rules as `list`).
- New `ToolResources` field:

  ```motoko
  filesystem : ?{
    state : FilesystemModel.FilesystemState; // this agent's isolated filesystem instance
    write : Bool;
  };

  ```

- New admin tool handlers in `tools/handlers/filesystem/`:
  - `create-file-entry-handler.mo` — Creates a new file entry. Fails if path already exists (use `update` for overwrites).
  - `update-file-entry-handler.mo` — Updates content and/or description of an existing file entry. Fails if path doesn't exist.
  - `get-file-entry-handler.mo` — Reads a single file entry by path.
  - `list-file-entries-handler.mo` — Lists file entries by path prefix. Returns path, name, extension, description (no content — too large for listing).
  - `delete-file-entry-handler.mo` — Deletes a file entry by path.
  - (Note: these admin CRUD tools are for internal/setup use only; agents use `file_read`, `file_write`, `delete_file_entry` at runtime.)
- Persistent state: `allFilesystemStates` added to `main.mo` as `Map<Nat, FilesystemModel.FilesystemState>` (keyed by agent ID). The current agent's `FilesystemState` is extracted by ID and passed through `EventProcessingContext`.

**Design Notes**

- **Agent-scoped and isolated**: each agent owns its own `FilesystemState` instance. There is no shared filesystem — agents cannot read or write each other's files. If an agent needs to share knowledge, it does so through Slack messages, not through the filesystem.
- **Path uniqueness**: paths are unique within a single agent's filesystem. `create` rejects if path exists; `update` rejects if path doesn't exist.
- **No content-size limit enforced in v0.5**: the IC's stable memory limits apply naturally. A future task may add explicit limits.
- **Agent deletion leaves orphaned filesystem state (not cleaned up in v0.5)**: `allFilesystemStates` is keyed by agent ID. When `unregister_agent` removes an agent, its `FilesystemState` entry in `allFilesystemStates` is not deleted — it becomes orphaned stable memory. Explicit cleanup on agent deletion is deferred to a future task.
- **Skills are just file entries**: no separate skill model. Skill-specific conventions (e.g., `/skills/<id>/SKILL.md`) are enforced by convention in tool descriptions, not by the model.

**Source Steps**

1. New file: `models/filesystem-model.mo` — `FileEntry` type (no `workspaceId`), `FilesystemState` type alias, `create`, `update`, `get`, `delete`, `list`, `listPaths`, path validation utility (rejects paths that: don't start with `/`, contain `..` segments, contain consecutive `/`, or end with `/`).
2. `tool-types.mo` — Add `filesystem` field to `ToolResources` (no `workspaceId`, no `agentId` — the state is already agent-resolved).
3. New files: `tools/handlers/filesystem/create-file-entry-handler.mo`, `update-file-entry-handler.mo`, `get-file-entry-handler.mo`, `list-file-entries-handler.mo`, `delete-file-entry-handler.mo`.
4. `tools/function-tool-registry.mo` — Import handlers, add tool definitions with JSON schemas, wire into admin tool set (gated on `resources.filesystem`).
5. `main.mo` — Add `allFilesystemStates : Map<Nat, FilesystemModel.FilesystemState>` to persistent state (keyed by agent ID). On each request, look up the dispatched agent's ID, extract its `FilesystemState` (defaulting to empty if first use), and pass it through the context.
6. `events/types/event-processing-context.mo` — Add `filesystemState : FilesystemModel.FilesystemState` to context (already resolved to the current agent's instance before passing in).
7. `agents/admin/org-admin-agent.mo` — Do NOT wire admin CRUD tools; admin agent will use `file_read`/`file_write`/`delete_file_entry` at runtime (wired in 5.4).
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (filesystem-model): `create` → `get` round-trip. `update` existing → overwrites. `delete` existing → returns entry. `delete` missing → error. `list` with prefix `/skills/` returns only entries under `/skills/`. `list` with `/` returns all. Empty filesystem returns `[]`. `create` with duplicate path → error. `update` with missing path → error. Prefix boundary: `list` with `/skill/` does NOT match `/skills/foo.md`. `list` with prefix not ending in `/` → error. Path validation: non-absolute path (`skills/foo.md`) → error. Path with `..` segment (`/skills/../secrets`) → error. Path with consecutive slashes (`/skills//foo.md`) → error. Path with trailing slash (`/skills/`) → error.
- Unit test (create-file-entry-handler): valid payload → entry created. Duplicate path (handler calls model `create`) → error. Missing required fields → error.
- Unit test (update-file-entry-handler): existing path (handler calls model `update`) → updated. Non-existent path → error. Partial update (only content, or only description) → other fields preserved.
- Unit test (list-file-entries-handler): entries under `/skills/` listed when prefix is `/skills/`. Content excluded from listing output.
- Unit test (delete-file-entry-handler): existing path → deleted. Non-existent path → error.
- Integration test: admin agent creates, updates, reads, and deletes a file entry through the full Slack → LLM → file_read/file_write/delete_file_entry tool flow.

---

### 5.4 — Filesystem: Agent-Facing Tools (`file_read` / `file_write`)

**Goal**

Expose the Filesystem to all agents via `file_read`, `file_write`, and `delete_file_entry` tools, so any agent can read from, write to, and delete entries in its own filesystem during LLM tool loops. This enables agents to build persistent knowledge (notes, plans, drafts, skill documents) that survives across turns and sessions. Each agent reads/writes only its own filesystem; there is no cross-agent access.

**Current State (after 5.3)**

- Filesystem model exists with core operations.
- Admin CRUD tool handlers exist (for internal/setup use only, not wired to agents).
- All agents lack access to filesystem storage.
- `ToolResources.filesystem` exists but is not wired to any agent category.

**Desired State**

- Three new tools available to all agent categories (admin, planning, research, communication, etc.):
  - `file_read(path)` — Two unambiguous modes determined solely by the path argument:
    - **Path ending in `/`** → directory listing. Returns `[{ path, description }]` for all entries whose path starts with that prefix. Returns an empty array if nothing matches — never an error.
    - **Exact path (no trailing `/`)** → file read. Returns `{ path, name, extension, description, content }`. Returns an error if the path does not exist.
  - `file_write(path, content, description?)` — Creates or updates a file entry. If the path doesn't exist, creates it (auto-derives `name` and `extension` from the path). If it exists, updates content and optionally description. The `description` parameter is required on creation, optional on update.
  - `delete_file_entry(path)` — Deletes a file entry by exact path. Returns an error if path doesn't exist.
- Tools gated on `ToolResources.filesystem` (non-null = available; `write = true` enables `file_write` and `delete_file_entry`, read-only disables both).
- All agent category services (`org-admin-agent.mo`, `work-planning-agent.mo`, and future agents) wire `filesystem` into their `ToolResources` with appropriate access (read-only or read-write based on the agent's category/config). Each service receives only the calling agent's own `FilesystemState` — never another agent's.
- `EventProcessingContext` already carries the dispatched agent's `filesystemState` (wired in 5.3 for admin; extended here to all agent categories).

**Design Notes**

- **`file_read` and `file_write`** are the LLM-facing names (per ARCHITECTURE.md's planned tool list). All agents use these tools to manage their own filesystems at runtime. Admin CRUD tools in 5.3 are internal infrastructure only, not exposed to any agent.
- **`file_read` mode dispatch**: the trailing `/` on the path is the sole dispatch signal — it is never ambiguous. Paths ending in `/` always list; paths without a trailing `/` always read. A missing exact path is always an error; a listing with no matches is always an empty array. This eliminates any silent fallback behavior that would confuse the LLM.
- **Write access control**: all agents get `file_write` and `delete_file_entry` by default (writing to their own filesystem only). Read-only agents get `file_read` only. A future phase may restrict write access per-agent via `toolsAllowed` or per-path policies.
- **No embedding/search yet**: `file_search` (embedding-based retrieval) is deferred to a future phase. Agents use `file_read` with path prefix for now.

**Source Steps**

1. New files: `tools/handlers/filesystem/file-read-handler.mo`, `tools/handlers/filesystem/file-write-handler.mo`, `tools/handlers/filesystem/delete-file-entry-handler.mo`.
2. `tools/function-tool-registry.mo` — Add `file_read`, `file_write`, and `delete_file_entry` tool definitions with JSON schemas. Gate on `resources.filesystem`. `file_write` and `delete_file_entry` additionally gated on `filesystem.write = true`.
3. `agents/admin/org-admin-agent.mo` — Wire `filesystem` into `ToolResources` with `write = true` (the admin agent's own filesystem instance).
4. `agents/planning/work-planning-agent.mo` — Wire `filesystem` into `ToolResources` with `write = true` (the planning agent's own filesystem instance).
5. `events/types/event-processing-context.mo` — Confirm `filesystemState` (the dispatched agent's isolated instance) is available to all agent categories.
6. `events/agent-router.mo` / `orchestrators/agent-orchestrator.mo` — Ensure `allFilesystemStates` lookup by agent ID happens before dispatch, so every category service receives the correct isolated `FilesystemState`.
7. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (file-read-handler): read existing exact path → returns content. Read non-existent exact path → error. Read with trailing `/` and matching entries → returns listing `[{ path, description }]`. Read with trailing `/` and no matches → returns empty array (no error).
- Unit test (file-write-handler): write to new path → creates entry with correct `name`, `extension`, and current `createdAt`. Write to existing path → updates content + `updatedAt` timestamp. Write without `description` to existing entry → preserves existing description. Write without `description` to new path → error (description required on creation).
- Unit test (delete-file-entry-handler): delete existing path → returns deleted entry. Delete non-existent path → error.
- Integration test: admin agent uses `file_write` to create an entry → `file_read` (exact path) to retrieve it → content matches. Planning agent uses `file_read("/")` (trailing `/`) → sees listing of all its own files, no entries from other agents. Each agent calls `delete_file_entry` on its own entries → succeeds.

---

## Decisions

- **Filesystem split into two PRs** because the full scope (model + admin tools + agent tools + wiring across all categories) is too large for one review. PR 5.3 delivers the foundation and admin management; PR 5.4 delivers the agent-facing tools that make the Filesystem useful in practice.
- **Agent-scoped filesystem, no cross-agent access**: each agent's filesystem is fully isolated. There is no shared filesystem, no cross-agent reads, and no admin-managed global knowledge base. If agents need to share knowledge, they do so through Slack messages. This enforces explicit, auditable communication.
- **No separate skill model**: skill documents are file entries under `/skills/` paths by convention, not a distinct data type. This keeps the persistence model unified.
- **`file_read`/`file_write` naming** follows ARCHITECTURE.md's planned tool list. They're the agent-facing API; admin CRUD tools use more explicit names (`create_file_entry`, etc.).
- **Embedding-based search deferred**: `file_search` requires an embedding pipeline which is a separate effort. Agents use `file_read` with path prefixes for discovery in v0.5.
