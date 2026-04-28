---
type: planning_archive
active_plan: PLAN.md
archive_strategy: chronological_snapshots
---

# PLAN.archive.md — Looping AI Archive Planning

Historical snapshots of planning cycles that were superseded by newer iterations.

This file is not actively maintained. Items listed here may already be completed, replaced, or implemented differently.

For the current active plan, see:
→ [PLAN.md](../../PLAN.md)

---

# Archive Index

| Date          | Notes                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------- |
| 9 March 2026  | Slack-first architecture: sessions, scoped access, tokens, agent tooling                                 |
| 5 April 2026  | Codespaces, OpenClaw, and Secrets Hardening                                                              |
| 23 April 2026 | Agent lifecycle scope and isolation; execution architecture (Envelope/Internal Engine/Effect Applicator) |

---

## Archive — 9 March 2026

Snapshot of the planning state at the time this iteration was archived.

---

## Phase 1 — Agent Registry & Routing

~~### 1.8 — Split org-admin agent from work-planning agent~~

**Goal**

Separate the monolithic `org-admin-agent.mo` into two focused agents: an **org-admin agent** (`agents/admin/`) responsible for organizational management (workspaces, channel anchors), and a new **work-planning agent** (`agents/planning/`) that carries all existing planning-domain tools (value streams, metrics, objectives). Introduce **typed per-category context structs** in `AgentRouter` so routing plumbing passes only the data each agent actually needs, and new categories never grow the router's flat param list.

**Current State**

- `agents/admin/org-admin-agent.mo` is monolithic: it holds value-stream, metric, and objective tools alongside the org-admin persona. It receives all planning resources (`workspaceValueStreamsState`, `valueStreamsMap`, etc.) even though no org-admin-specific tools exist yet.
- `AgentRouter.route()` passes a flat list of positional params covering **all** possible tool resources regardless of the category being dispatched to. As new categories diverge, this would grow unboundedly.
- `AgentCategory` has `#admin`, `#research`, `#communication`. `#research` is meant for "information gathering and planning" but is unimplemented; the planning work currently lives inside `#admin`.
- `ToolResources` in `tool-types.mo` has no workspace-management resource — only value streams, metrics, objectives, and the Groq API key.
- Workspace-management methods (`createWorkspace`, `listWorkspaces`, `setWorkspaceAdminChannel`, etc.) live exclusively in `main.mo` as principal-authenticated endpoints and are inaccessible as LLM tools.

**Desired State**

#### New category: `#planning`

`AgentCategory` gains `#planning`:

```motoko
public type AgentCategory = {
  #admin; // org administration: workspace & channel management
  #planning; // work planning: value streams, metrics, objectives
  #research; // stub — Phase 5
  #communication; // stub — Phase 5
};

```

`helpers.mo#categoryToRole` maps `#planning` → `#customAgent({ name; persona = ?"work planning specialist" })`.

#### Directory layout after this task

```
agents/
  admin/
    org-admin-agent.mo       ← org mgmt tools only; workspace tools added here
  planning/
    work-planning-agent.mo   ← extracted from current org-admin-agent.mo
```

#### `org-admin-agent.mo` — after refactor

- Stripped to the org-admin persona (already handled by `categoryToRole` → `#orgAdmin`).
- **No planning-domain resources** in its `process()` signature (`workspaceValueStreamsState`, etc. removed).
- `process()` accepts `AdminAgentCtx` (see router section below).
- **New workspace-management tools** wired via a new `workspaces` resource in `ToolResources`:
  - `list_workspaces` — lists all workspace records.
  - `create_workspace(name)` — creates a new workspace (mutates `WorkspacesState`).
  - `set_workspace_admin_channel(workspaceId, channelId)` — sets the admin channel anchor. Use `workspaceId = 0` to set the org-admin channel (org-owner only).
  - `set_workspace_member_channel(workspaceId, channelId)` — sets the member channel anchor.
- `buildInstructions` produces a concise org-admin persona block with no value-stream / metrics / objectives context.

**Mutable state for workspace write tools**: `WorkspacesState` already carries `var nextId` and a mutable `Map`, so it is mutable when passed by reference. The org-admin channel is stored as workspace 0's `adminChannelId` field — no separate wrapper needed; `AdminAgentCtx` carries `workspaces` directly.

#### `work-planning-agent.mo` — new file

- Direct extraction of the current `org-admin-agent.mo` `process()`, `buildInstructions`, `buildWorkspaceContext`, `buildContextMessages` logic.
- Persona via `categoryToRole(#planning, agent.name)` → `#customAgent` work-planning specialist.
- All existing tool resources, context building, and tool-filtering logic are unchanged.
- Lives at `agents/planning/work-planning-agent.mo`.

#### Typed context structs in `AgentRouter`

Replace the flat positional params on `route()` with a single `agentCtx : AgentCtx` variant:

```motoko
public type AdminAgentCtx = {
  workspaces : WorkspaceModel.WorkspacesState;
};

public type PlanningAgentCtx = {
  workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState;
  valueStreamsMap : ValueStreamModel.ValueStreamsMap;
  workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap;
  metricsRegistryState : MetricModel.MetricsRegistryState;
  metricDatapoints : MetricModel.MetricDatapointsStore;
  workspaceId : Nat;
};

public type AgentCtx = {
  #admin : AdminAgentCtx;
  #planning : PlanningAgentCtx;
  #research; // no ctx payload yet — stub
  #communication; // no ctx payload yet — stub
};

```

`route()` new signature:

```motoko
public func route(
  primaryAgent : AgentModel.AgentRecord,
  mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
  workspaceSecrets : ?Map.Map<Types.SecretId, SecretModel.EncryptedSecret>,
  conversationEntry : ?ConversationModel.TimelineEntry,
  agentCtx : AgentCtx,
  message : Text,
  encryptionKey : [Nat8],
) : async RouteResult;

```

The `switch (primaryAgent.category)` dispatch also validates that the `AgentCtx` variant tag matches the agent's category. A mismatch logs a warning and returns `#err({ message = "agent context mismatch: …" ; steps = [] })`.

#### `AgentOrchestrator` changes

- `orchestrateAgentTalk` accepts `agentCtx : AgentCtx` instead of the flat planning params.
- Switches on `agentCtx`:
  - `#admin(ctx)` → `OrgAdminAgent.process(agent, mcpToolRegistry, conversationEntry, ctx, message, apiKey)`.
  - `#planning(ctx)` → `WorkPlanningAgent.process(agent, mcpToolRegistry, conversationEntry, ctx, message, apiKey)`.
  - `#research` / `#communication` → `#err("category not implemented")`.
- The `secretId` / `isSecretAllowed` guard is category-agnostic and runs before the dispatch as today.

#### `MessageHandler` changes

- Before calling `AgentRouter.route`, construct `AgentCtx` by switching on `primaryAgent.category`:
  - `#admin` → `#admin({ workspaces = ctx.workspaces })`.
  - `#planning` → `#planning({ workspaceValueStreamsState = …; valueStreamsMap = …; … })`.
  - `#research` → `#research`.
  - `#communication` → `#communication`.
- This is the single point that knows all available data; it builds the right context for the router.

#### `EventProcessingContext` changes

No changes needed for the org-admin channel — it is derived from `workspaces` (workspace 0's `adminChannelId`) which is already present in the context.

**Source Steps**

1. **`models/agent-model.mo`** — add `#planning` to `AgentCategory`. No logic changes needed; `getFirstByCategory` already handles all variants by exhaustive match.

2. **`agents/helpers.mo`** — add `#planning` branch to `categoryToRole`:

   ```motoko
   case (#planning) {
     #customAgent({ name; persona = ?"work planning specialist" });
   };

   ```

3. **`tools/tool-types.mo`** — add `workspaces` optional field to `ToolResources`:

   ```motoko
   workspaces : ?{
     state : WorkspaceModel.WorkspacesState;
     write : Bool;
   };

   ```

4. **`tools/function-tool-registry.mo`** — add workspace-management tools section, gated on `resources.workspaces`. Read tools (`list_workspaces`, `get_workspace`) are always available when the resource is present; write tools (`create_workspace`, `set_workspace_admin_channel`, `set_workspace_member_channel`) are only added when `write = true`. Setting workspace 0's admin channel (`set_workspace_admin_channel(0, ...)`) already enforces org-owner-only at the canister level.

5. **Create `agents/planning/work-planning-agent.mo`** — extract current `org-admin-agent.mo` logic verbatim; change `categoryToRole` call to use `#planning`; keep all value-stream / metrics / objectives tool wiring and context building. Accept `PlanningAgentCtx` as a parameter instead of the flat resource params.

6. **Refactor `agents/admin/org-admin-agent.mo`** — strip planning-domain imports (`ValueStreamModel`, `ObjectiveModel`, `MetricModel`) and all associated logic; accept `AdminAgentCtx`; wire workspace tools via `ToolResources`; simplify `buildInstructions` to produce an org-admin persona only.

7. **`events/agent-router.mo`** — define `AdminAgentCtx`, `PlanningAgentCtx`, `AgentCtx` types; refactor `route()` to accept `agentCtx : AgentCtx`; pass the ctx through to `AgentOrchestrator.orchestrateAgentTalk`.

8. **`orchestrators/agent-orchestrator.mo`** — accept `agentCtx : AgentCtx` instead of flat params; dispatch `OrgAdminAgent.process` or `WorkPlanningAgent.process` based on ctx variant; retain `secretId` guard before dispatch.

9. **`events/types/event-processing-context.mo`** — no changes needed for org-admin channel; `workspaces` field already provides access to workspace 0's `adminChannelId`.

10. **`events/handlers/message-handler.mo`** — build `AgentCtx` from `primaryAgent.category` and the contents of `EventProcessingContext`; pass it to `AgentRouter.route` in place of the old flat params.

11. **`main.mo`**: no changes needed for org-admin channel state — it is stored as workspace 0's `adminChannelId` via `setWorkspaceAdminChannel(0, ...)` (org-owner only guard already enforced).

12. **Verify** — `icp build control-plane-core` — no compilation errors.

**Test Steps**

_Unit tests — new file `tests/unit-tests/control-plane-core/agents/planning/work-planning-agent.test.mo`_:

- **Category-to-role**: `#planning` → `#customAgent` with `"work planning specialist"` persona.
- Existing planning-domain tool-filtering and instruction-building tests ported here.

_Unit tests — updated `tests/unit-tests/control-plane-core/agents/admin/org-admin-agent.test.mo`_:

- **No planning tools in tool set**: `list_workspaces` is present; `save_value_stream` is absent.
- **`buildInstructions`**: no value-stream or metrics blocks; org-admin persona block present.
- **`create_workspace` tool**: call handler with `"My Team"` → workspace created in `WorkspacesState`.
- **`list_workspaces` tool**: two pre-seeded workspaces → tool returns both records.
- **`set_workspace_admin_channel` tool**: sets `adminChannelId` on the target workspace.
- **`get_org_admin_channel` tool**: reads workspace 0's `adminChannelId`; returns null when unset, returns the channel ID when set.

_Unit tests — updated `tests/unit-tests/control-plane-core/events/agent-router.test.mo`_:

- **`#admin` category + `#admin` ctx → dispatches to org-admin agent** (orchestrator stub returns `#ok`).
- **`#planning` category + `#planning` ctx → dispatches to work-planning agent**.
- **Category/ctx mismatch** (e.g. `#admin` category with `#planning` ctx) → `#err("agent context mismatch")`.
- **`#research` → `#err("category not implemented")`**.
- **`#communication` → `#err("category not implemented")`**.

_Integration tests — updated `tests/integration-tests/control-plane-core/workspace-admin-talk.spec.ts`_:

- Existing planning-flow tests migrated to register a `#planning` agent; all assertions unchanged.
- **New — org-admin workspace list**: register a `#admin` agent; send `"list my workspaces"` → `list_workspaces` step appears; response enumerates workspace names.
- **New — org-admin create workspace**: register a `#admin` agent; send `"create a workspace called Ops"` → `create_workspace` step appears; canister state reflects the new workspace.

---

## Phase 2 — Slack-Only Write Surface

**Goal**: Ensure all mutations enter through Slack events. Remove any remaining update call endpoints exposed to external clients.

### 2.1 — Migrate all public update methods to tools; remove direct API surface

**Goal**

Remove every `public shared` method from `main.mo` that is not `http_request` / `http_request_update`. Each domain is migrated (to agent tools) or deleted (legacy/internal) one at a time, with a build-and-commit checkpoint after each step. After this task, the only way to mutate canister state is through a Slack webhook event processed by an agent.

**Current State**

- `main.mo` exposes ~40 `public shared` methods across 9 non-HTTP domains.
- Several domains have partial tool handler coverage already: workspace (all 4), metrics (3 of 8 operations), value streams (2 of 6), objectives (5 of 10).
- Integration tests call these endpoints directly via PocketIC actor calls.
- State can be mutated either through Slack webhooks or direct canister calls — the direct path must be closed.

**Desired State**

- Only `http_request` (query) and `http_request_update` (update) remain as public methods in `main.mo`.
- All remaining mutations flow through Slack → webhook → event → agent tool call.
- Each domain's test coverage lives in unit tests against its tool handler(s), not integration tests against the actor.

**Domain disposition**

| Domain                              | Decision                               | Agent       | Existing handlers | Tests                                        |
| ----------------------------------- | -------------------------------------- | ----------- | ----------------- | -------------------------------------------- |
| OrgAdmin Management                 | DELETE (legacy auth, covered by 2.6)   | —           | none              | delete `admin.spec.ts`                       |
| Workspace Channel-Anchor Management | REMOVE endpoints (tools added in 1.8)  | `#admin`    | all 4 ✓           | migrate `workspace-channels.spec.ts` → unit  |
| Metrics API                         | REMOVE endpoints; add missing handlers | `#planning` | 3 of 8 ✓          | migrate `metrics.spec.ts` → unit             |
| Value Streams API                   | REMOVE endpoints; add missing handlers | `#planning` | 2 of 6 ✓          | migrate `value-streams.spec.ts` → unit       |
| Objectives API                      | REMOVE endpoints; add missing handlers | `#planning` | 5 of 10 ✓         | migrate `objectives.spec.ts` → unit          |
| Agent Registry                      | MIGRATE to tools                       | `#admin`    | none              | new unit tests                               |
| MCP Tool Management                 | MIGRATE to tools                       | `#admin`    | none              | migrate `mcp-tools.spec.ts` → unit           |
| Secrets Management                  | MIGRATE to tools                       | `#admin`    | none              | migrate `secrets.spec.ts` → unit             |
| Key Cache Management                | DELETE (internal; timer covers it)     | —           | none              | remove cache cases from `encryption.spec.ts` |
| Event Queue Stats & Management      | MIGRATE to tools                       | `#admin`    | none              | migrate `event-store-admin.spec.ts` → unit   |

**Source Steps**

Each step below is an independent, buildable, committable unit. Verify with `icp build control-plane-core` and `bun run tsc --noEmit` after each before committing.

---

**Step 1 — Delete: OrgAdmin Management** _(partially reverted: `addOrgAdmin`, `addWorkspaceAdmin`, `addWorkspaceMember`, `getOrgAdmins`, `getWorkspaceMembers`, `isCallerOrgAdmin`, `isCallerWorkspaceMember` restored to unblock test helpers; to be removed again in Task 2.5 together with the test migration)_

_Methods to delete from `main.mo`:_ `addOrgAdmin`, `getOrgAdmins`, `isCallerOrgAdmin`, `addWorkspaceAdmin`, `addWorkspaceMember`, `getWorkspaceMembers`, `isCallerWorkspaceMember`.

- These are Principal-based auth helpers that will be fully removed in Task 2.6. They serve no architectural purpose after 2.6 and have no LLM-agent utility.
- Delete the entire `// OrgAdmin Management` section from `main.mo`.
- Delete `tests/integration-tests/control-plane-core/admin.spec.ts` (it exclusively tests these methods).
- Verify.

---

~~**Step 2 — Remove endpoints: Workspace Channel-Anchor Management**~~

_Methods to delete from `main.mo`:_ `createWorkspace`, `listWorkspaces`, `setWorkspaceAdminChannel`, `setWorkspaceMemberChannel`.

- Tool handlers for all four already exist (`create-workspace-handler.mo`, `list-workspaces-handler.mo`, `set-workspace-admin-channel-handler.mo`, `set-workspace-member-channel-handler.mo`) and are wired into `org-admin-agent.mo` since Task 1.8.
- Delete the entire `// Workspace Channel-Anchor Management` section from `main.mo`.
- Migrate test coverage: port the meaningful cases from `tests/integration-tests/control-plane-core/workspace-channels.spec.ts` into unit tests under `tests/unit-tests/control-plane-core/tools/handlers/` that call the handler functions directly with a `WorkspacesState`. These are pure functional tests — no actor needed.
- Delete `tests/integration-tests/control-plane-core/workspace-channels.spec.ts`.
- Verify.

---

~~**Step 3 — Add missing handlers + remove endpoints: Metrics API**~~

_Methods to delete from `main.mo`:_ `registerMetric`, `getMetric`, `listMetrics`, `recordMetricDatapoint`, `getMetricDatapoints`, `getLatestMetricDatapoint`, `unregisterMetric`, `purgeOldMetricDatapoints`.

_Existing handlers (keep, wire if not already):_ `create-metric-handler.mo`, `update-metric-handler.mo`, `get-metric-datapoints-handler.mo`.

_New handlers to create in `tools/handlers/`:_

- `list-metrics-handler.mo` — lists all registered metrics.
- `get-metric-handler.mo` — gets a single metric by ID.
- `delete-metric-handler.mo` — unregisters a metric and purges its datapoints.
- `get-latest-metric-datapoint-handler.mo` — gets the latest datapoint for a metric.
- `record-metric-datapoint-handler.mo` — records a single datapoint (if not already wired).

Wire all new handlers into `work-planning-agent.mo` via `FunctionToolRegistry`.

Migrate test coverage: port cases from `tests/integration-tests/control-plane-core/metrics.spec.ts` into unit tests under `tests/unit-tests/control-plane-core/tools/handlers/metrics/`. Delete `metrics.spec.ts`.

Verify.

---

~~**Step 4 — Add missing handlers + remove endpoints: Value Streams API**~~

_Methods to delete from `main.mo`:_ `createValueStream`, `getValueStream`, `listValueStreams`, `updateValueStream`, `deleteValueStream`, `setValueStreamPlan`.

_Existing handlers (keep):_ `save-value-stream-handler.mo` (create + update), `save-plan-handler.mo`.

_New handlers to create:_

- `list-value-streams-handler.mo` — lists all value streams in a workspace.
- `get-value-stream-handler.mo` — gets a single value stream by ID.
- `delete-value-stream-handler.mo` — deletes a value stream and its objectives.

Wire new handlers into `work-planning-agent.mo`.

Migrate: port `value-streams.spec.ts` → unit tests under `tests/unit-tests/control-plane-core/tools/handlers/value-streams/`. Delete `value-streams.spec.ts`.

Verify.

---

~~**Step 5 — Add missing handlers + remove endpoints: Objectives API**~~

_Methods to delete from `main.mo`:_ `addObjective`, `getObjective`, `listObjectives`, `updateObjective`, `archiveObjective`, `recordObjectiveDatapoint`, `getObjectiveHistory`, `addObjectiveDatapointComment`, `addImpactReview`, `getImpactReviews`.

_Existing handlers (keep):_ `create-objective-handler.mo`, `update-objective-handler.mo`, `archive-objective-handler.mo`, `record-objective-datapoint-handler.mo`, `add-impact-review-handler.mo`.

_New handlers to create:_

- `list-objectives-handler.mo` — lists all objectives for a value stream.
- `get-objective-handler.mo` — gets a single objective by ID.
- `get-objective-history-handler.mo` — returns the datapoint history array.
- `add-objective-datapoint-comment-handler.mo` — adds a comment to a history entry.
- `get-impact-reviews-handler.mo` — returns all impact reviews for an objective.

Wire new handlers into `work-planning-agent.mo`.

Migrate: port `objectives.spec.ts` → unit tests under `tests/unit-tests/control-plane-core/tools/handlers/objectives/`. Delete `objectives.spec.ts`.

Verify.

---

~~**Step 6 — Migrate to tools: Agent Registry**~~

_Methods to delete from `main.mo`:_ `registerAgent`, `getRegisteredAgent`, `updateRegisteredAgent`, `unregisterAgent`, `getRegisteredAgentById`, `listRegisteredAgents`, `setAgentWorkspaceSecrets`.

_New handlers to create in `tools/handlers/agents/`:_

- `register-agent-handler.mo` — registers a new agent in the registry.
- `list-agents-handler.mo` — lists all registered agents.
- `get-agent-handler.mo` — looks up an agent by name or ID.
- `update-agent-handler.mo` — updates an agent's configuration.
- `unregister-agent-handler.mo` — removes an agent from the registry.

Wire all into `org-admin-agent.mo`.

Add unit tests under `tests/unit-tests/control-plane-core/tools/handlers/agents/` covering each handler's happy path and key error paths.

Verify.

---

~~**Step 7 — Migrate to tools: MCP Tool Management**~~

_Methods to delete from `main.mo`:_ `registerMcpTool`, `unregisterMcpTool`, `listMcpTools`.

_New handlers to create in `tools/handlers/mcp/`:_

- `register-mcp-tool-handler.mo`
- `unregister-mcp-tool-handler.mo`
- `list-mcp-tools-handler.mo`

Wire into `org-admin-agent.mo`.

Migrate: port `mcp-tools.spec.ts` → unit tests under `tests/unit-tests/control-plane-core/tools/handlers/mcp/`. Delete `mcp-tools.spec.ts`.

Verify.

---

~~**Step 8 — Migrate to tools: Secrets Management**~~

_Methods to delete from `main.mo`:_ `storeSecret`, `getWorkspaceSecrets`, `deleteSecret`.

_New handlers to create in `tools/handlers/secrets/`:_

- `store-secret-handler.mo`
- `get-workspace-secrets-handler.mo`
- `delete-secret-handler.mo`

Wire into `org-admin-agent.mo`. The auth guard (only org admins may store Slack secrets; workspace admins may store LLM keys) must be enforced inside each handler, not just in main.mo.

Migrate: port `secrets.spec.ts` → unit tests under `tests/unit-tests/control-plane-core/tools/handlers/secrets/`. Delete `secrets.spec.ts`.

Verify.

---

~~**Step 9 — Delete: Key Cache Management**~~

_Methods to delete from `main.mo`:_ `clearKeyCache`, `getKeyCacheStats`.

- The 30-day timer already handles cache clearing. No agent needs to inspect or clear the cache on demand; these are purely internal maintenance methods.
- Remove the `// Key Cache Management` section from `main.mo`.
- Remove the two test cases for `clearKeyCache` / `getKeyCacheStats` from `tests/integration-tests/control-plane-core/encryption.spec.ts` (keep the key-derivation tests).
- Verify.

---

~~**Step 10 — Migrate to tools: Event Queue Stats & Management**~~

_Methods to delete from `main.mo`:_ `getEventStoreStats`, `getFailedEvents`, `deleteFailedEvents`.

_New handlers to create in `tools/handlers/events/`:_

- `get-event-store-stats-handler.mo`
- `get-failed-events-handler.mo`
- `delete-failed-events-handler.mo`

Wire into `org-admin-agent.mo`.

Migrate: port `event-store-admin.spec.ts` → unit tests under `tests/unit-tests/control-plane-core/tools/handlers/events/`. Delete `event-store-admin.spec.ts`.

Verify.

---

**Step 11 — Improve Timers & Cleanup AuthMiddleware test**

- ?

---

**Test Steps**

After all 10 steps, the only remaining integration tests that exercise `main.mo` public methods are:

- `http-requests.spec.ts` — `http_request` (GET/non-POST) query endpoint.
- `slack-webhook.spec.ts` — full Slack webhook pipeline through `http_request_update`.
- `timers.spec.ts` — timer callback behavior.
- `encryption.spec.ts` — key derivation (cache parts removed in Step 9).

Run `bun run test:unit` to confirm all unit tests pass. Run `bun run tsc --noEmit` to confirm no TypeScript regressions in the test suite.

### 2.2 — Session tracking model

- New persistent model: `Map<slackMessageId, SessionRecord>`.
- `SessionRecord = { sessionId, slackMessageId, userAuthContextId, agentId, parentSessionId }`.
- `sessionId` format: `{agent_name}_{user_id}_{unique_incremental_id}`.
- `parentSessionId`: links to the session that triggered this one (forms delegation chain).
- Support delegation chain reconstruction by walking `parentSessionId` links.
- Retention policy: bounded by time or count (TBD).

### 2.3 — Access scoping on models

- Add visibility metadata to models: `read: #org | #team | #admin`, `write: #org | #team | #admin`.
- Enforce at the service level: check `userAuthContext.workspaceScopes` (and `isOrgAdmin` for org-level resources) against the resource's required level before read/write operations.
- Examples: objectives (`read: org`, `write: admin`), tasks (`read: org`, `write: team`).

### 2.4 — App install and setup flow

- On canister init or first Slack event: call `conversations.list` + `users.list`.
- Identify Primary Owner (`is_primary_owner: true`).
- Detect or request creation of `#looping-ai-org-admins`.
- Store channel ID anchor. Populate org admin user cache entries.

### 2.5 — Remove legacy auth

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

---

## END of Archive — 9 March 2026

---

---

## Archive — 5 April 2026

Snapshot of the planning state at the time this iteration was archived.

---

## Plan: v0.3 — Codespaces, OpenClaw, and Secrets Hardening

**TL;DR**: Evolve from a Slack-only canister with embedded LLM calls to a platform that manages remote AI agents running in GitHub Codespaces via OpenClaw. The canister becomes the control plane: it manages codespace lifecycles (via GitHub Device Flow + Codespaces API), pushes agent configurations to OpenClaw instances (via an Express sidecar), receives structured agent responses (via a new webhook endpoint), and orchestrates the final Slack replies. Simultaneously, refactor from Groq to OpenRouter as the canister’s own LLM provider, harden the secrets system with audit trails, and introduce a flexible credential cascade with custom secret types.

---

## Phase A — Foundation Refactors (no new features, unblocks everything)

~~### A.0 — Agent Execution Types~~

**What**: Introduce the concept of two fundamentally different agent execution types.

**Changes**:

- `agent-model.mo`: Add `executionType` to `AgentRecord`:
  ```
  AgentExecutionType = {
    #api;                    // Runs inside the canister, calls LLM APIs directly (OpenRouter)
    #runtime : RuntimeType;  // Runs remotely in a managed environment
  };
  RuntimeType = {
    #openClaw : { openClawVersion: Text };  // Runs in a codespace via OpenClaw gateway
  };
  ```
- `#api` agents: Current behavior. The canister calls OpenRouter directly, executes tool loops in-canister, posts replies to Slack. Examples: workspace-admin, work-planning agents.
- `#runtime(#openClaw)` agents: The canister delegates work to a remote OpenClaw instance running in a GitHub Codespace. The canister sends a task via the sidecar, receives a structured JSON response via webhook, then composes and posts the final Slack reply.
- The `AgentRouter` dispatch logic must branch on `executionType`:
  - `#api` → existing orchestrator flow (in-canister LLM loop).
  - `#runtime(#openClaw)` → new flow: send task to sidecar → await webhook response → compose Slack reply.
- The `#api` agents use canister-level secrets (OpenRouter key). The `#runtime(#openClaw)` agents use secrets pushed to the codespace (Anthropic keys, OpenRouter keys, etc. via the credential cascade).
- The pre-seeded "workspace-admin" agent remains `#api`. New user-created agents default to `#runtime(#openClaw)` but can be `#api` if the admin chooses.
- `openClawVersion` inside `#openClaw` is captured at deploy time from the sidecar health check and stored with the agent. It stays pinned until an explicit upgrade.

**Verification**: `icp build control-plane-core`. Unit tests for type construction and router branching.

~~### A.1 — Refactor Groq → OpenRouter~~

**What**: Replace Groq API integration with OpenRouter. Same OpenAI-compatible chat completions API, same model (`openai/gpt-oss-120b` via Groq provider on OpenRouter).

**Changes**:

- `types.mo`: Replace `LlmProvider = #openai | #groq` → `#openRouter`. Add `#openRouterApiKey` to `SecretId`. Remove `#groqApiKey` from `SecretId` and `OrgCriticalSecretId`.
- `constants.mo`: `ADMIN_TALK_PROVIDER = #openRouter`, `ADMIN_TALK_SECRET = #openRouterApiKey`.
- Rename `groq-wrapper.mo` → `openrouter-wrapper.mo`. Update API URL from `api.groq.com` → `openrouter.ai/api/v1`. Update headers (add `HTTP-Referer`, `X-Title` per OpenRouter docs). Keep request/response types (OpenAI-compatible). Confirm `CompoundChatCompletionRequest` search settings work or adapt for OpenRouter’s native web search.
- `agent-model.mo`: `LlmModel = #openRouter(OpenRouterModel)`, `OpenRouterModel = #gpt_oss_120b`. Update `llmModelToText` and `llmModelToSecretId`.
- Update all references across agents, orchestrators, services.
- Pre-seeded agent: secretsAllowed changes to `#openRouterApiKey`.

**Verification**: `icp build control-plane-core`, re-record integration test cassettes with OpenRouter.

~~### A.2 — Secrets Hardening: Changelog + Access Log~~

**What**: Add audit trails to the secrets system, modeled after `SlackUserModel`’s `AccessChangeLog` pattern.

**Changes**:

- `secret-model.mo`: Add per-workspace `SecretChangeLog` (append-only list):
  - Entry: `{ timestamp, source: #adminTool | #reconciliation | #system, changeType: #stored(SecretId) | #deleted(SecretId) | #accessed(SecretId, agentId: ?Nat) }`
  - `SecretAccessLog` for tracking read access (which agent decrypted which secret).
  - `SecretAuditState = { var changeLog: List<SecretChangeEntry>, var accessLog: List<SecretAccessEntry> }` per workspace.
- Integrate access logging at the point secrets are decrypted (in agent orchestrators and tool handlers).
- Add `purgeOldLogs(retentionNs)` following the `SlackUserModel` pattern.
- Wire into weekly reconciliation timer for log cleanup.

**Verification**: Unit tests for changelog append, purge, and query.

~~### A.3 — Custom Secret Types + Credential Cascade~~

**What**: Extend `SecretId` with `#custom(Text)` variant. Introduce agent-level secret mapping that enables the org→team→agent override chain.

**Changes**:

- `types.mo` / `secret-model.mo`: Add `#custom(Text)` to `SecretId`. Update `compareSecretId` for stable ordering of custom keys.
- `agent-model.mo`: Add `secretMappings: [(customSecretName: Text, targetSecretId: SecretId)]` to `AgentRecord`. This lets an admin say "for this agent, use custom secret 'my-anthropic-key' as the #anthropicApiKey".
- Add `#openRouterApiKey` and `#anthropicApiKey` and `#anthropicSetupToken` to `SecretId`.
- **Credential resolution logic** (new utility):
  1. Check agent’s `secretMappings` for a mapped custom secret in the agent’s workspace → decrypt from that workspace.
  2. If not found, check the agent’s workspace for the standard secret ID.
  3. If not found, fall back to org workspace (ws 0) for the standard secret ID.
  - This is a pure function: `resolveSecret(agent, workspaceId, targetSecretId, secretsMap, encryptionKeys) → ?Text`.

**Verification**: Unit tests for cascade resolution with all 3 levels.

---

## Phase B — GitHub Codespaces Integration

### B.1 — GitHub Device Flow Auth

**What**: Implement OAuth Device Flow (RFC 8628) for GitHub, allowing workspace admins to authenticate their GitHub account.

**Changes**:

- New wrapper: `wrappers/github-wrapper.mo` — HTTP outcall methods for:
  - `requestDeviceCode(clientId)` → `{ device_code, user_code, verification_uri, expires_in, interval }`
  - `pollAccessToken(clientId, deviceCode)` → `{ access_token, token_type, scope }` or polling states (`authorization_pending`, `slow_down`, `expired_token`)
  - Codespaces API calls (see B.2).
- New `SecretId` variant: `#githubUserToken`. Stored per-workspace, encrypted like other secrets.
- New tool handler: `start-github-auth-handler.mo` — initiates Device Flow, returns `user_code` + `verification_uri` for the admin to complete in browser.
- New tool handler: `complete-github-auth-handler.mo` — polls until authorized, stores the token.
- Guard: only workspace admins can initiate/complete auth (checked via `userAuthContext`).

**Verification**: Integration test with cassette for Device Flow exchange.

### B.2 — Codespace Lifecycle Management

**What**: CRUD operations for GitHub Codespaces via the Codespaces REST API, scoped per workspace.

**Changes**:

- `github-wrapper.mo` additions:
  - `createCodespace(token, repo, ref, devcontainerPath)` — POST `/user/codespaces` (hardcoded to cheapest 2-core machine type)
  - `startCodespace(token, codespaceName)` — POST `/user/codespaces/{name}/start`
  - `stopCodespace(token, codespaceName)` — POST `/user/codespaces/{name}/stop`
  - `deleteCodespace(token, codespaceName)` — DELETE `/user/codespaces/{name}`
  - `getCodespace(token, codespaceName)` — GET `/user/codespaces/{name}`
  - `listCodespaces(token)` — GET `/user/codespaces`
- New model: `codespace-model.mo`:
  - `CodespaceRecord = { workspaceId: Nat, codespaceName: Text, repoFullName: Text, status: CodespaceStatus, sidecarUrl: ?Text, sidecarSecret: Text, createdAt: Int, lastHealthCheck: ?Int }`
  - `CodespaceStatus = #creating | #running | #stopped | #deleted | #unknown`
  - `CodespacesState = Map<Nat, CodespaceRecord>` (workspace → codespace).
- Tool handlers (wired into `#admin` agent):
  - `create-codespace-handler.mo`, `start-codespace-handler.mo`, `stop-codespace-handler.mo`, `delete-codespace-handler.mo`, `list-codespaces-handler.mo`, `rotate-sidecar-secret-handler.mo`
- Guard: only workspace admins can manage codespaces.

**Verification**: Unit tests for model CRUD. Integration tests with cassettes for GitHub API calls.

### B.3 — GitHub Webhook Ingress (Codespace Lifecycle Events)

**What**: New canister endpoint to receive GitHub webhooks for codespace lifecycle events.

**Changes**:

- `slack-adapter.mo` → refactor to a more generic `webhook-adapter.mo` or add a parallel `github-adapter.mo`:
  - New path: POST `/github/webhook` on `http_request_update`.
  - GitHub webhook signature verification: HMAC-SHA256 with `X-Hub-Signature-256` header, using a stored webhook secret.
  - Parse `codespaces` event payloads: `action` = `created | started | stopped | deleted`.
  - Normalize into internal event: `#codespaceLifecycle({ codespaceName, action, workspaceId })`.
- `event-router.mo`: New handler for `#codespaceLifecycle` events → update `CodespaceRecord.status`.
- New `SecretId`: `#githubWebhookSecret` (org-level).

**Verification**: Integration test simulating GitHub webhook delivery with signature verification.

---

## Phase C — OpenClaw Integration

### C.1 — Sidecar Communication Protocol

**What**: Define the protocol between the canister and the Express sidecar running inside each codespace alongside OpenClaw.

**Design**:

- Sidecar exposes endpoints:
  - `POST /config/agents` — Create/update/delete an OpenClaw agent (pushes to `openclaw.json` + workspace files).
  - `POST /config/secrets` — Push decrypted secrets into OpenClaw’s env/auth-profiles.
  - `POST /config/reload` — Trigger OpenClaw config hot-reload.
  - `POST /agent/run` — Trigger an agent task via OpenClaw’s `/hooks/agent` endpoint.
  - `GET /health` — Health check. Returns OpenClaw version (captured per-agent at deploy time).
- Auth: HMAC-SHA256 on request body + timestamp header, using a shared `sidecarSecret` (generated at codespace creation, stored in `CodespaceRecord`).
- New wrapper: `wrappers/sidecar-wrapper.mo` — HTTP outcall methods for each sidecar endpoint.

**Verification**: Unit tests for HMAC generation. Integration test with cassette for sidecar health check.

### C.2 — OpenClaw Webhook Ingress (Agent Responses)

**What**: New canister endpoint to receive structured agent responses from OpenClaw.

**Changes**:

- New path: POST `/openclaw/webhook` on `http_request_update`.
- Auth: HMAC-SHA256 verification using the workspace’s `sidecarSecret`.
- Payload schema (structured JSON):
  ```
  {
    workspaceId: Nat,
    agentId: Text,        // OpenClaw agent ID
    sessionKey: Text,
    requestId: Text,      // correlates to the original agent/run request
    result: {
      text: Text,
      toolsUsed: [{ name: Text, result: Text }],
      tokensUsed: { prompt: Nat, completion: Nat },
      model: Text,
      durationMs: Nat
    },
    status: "completed" | "failed" | "timeout"
  }
  ```
- Normalize into internal event: `#openClawAgentResponse(...)`.
- `event-router.mo`: New handler that:
  1. Correlates `requestId` back to the pending agent session.
  2. Injects the response as a tool result into the LLM conversation.
  3. Lets the canister’s LLM compose the final Slack reply.

**Verification**: Integration test with cassette for webhook delivery + response composition.

### C.3 — Agent Configuration Push

**What**: When a workspace admin configures an agent (via `#admin` tools), translate the canister’s `AgentRecord` into OpenClaw configuration and push it to the codespace.

**Changes**:

- New service: `services/openclaw-config-service.mo`:
  - `buildOpenClawAgentConfig(agent: AgentRecord, template: ?AgentTemplate) → OpenClawAgentConfig` — Translates canister agent definition into OpenClaw’s JSON config (workspace files like AGENTS.md, SOUL.md, model, tools, sandbox settings).
  - `pushAgentConfig(codespace: CodespaceRecord, config: OpenClawAgentConfig)` — Calls sidecar `/config/agents`.
  - `pushSecrets(codespace: CodespaceRecord, secrets: [(Text, Text)])` — Calls sidecar `/config/secrets`.
- New tool handlers:
  - `deploy-agent-handler.mo` — Deploys agent config to codespace.
  - `sync-agent-secrets-handler.mo` — Pushes resolved secrets to codespace.

**Verification**: Unit tests for config translation. Integration test for deploy flow.

### C.4 — Agent Templates

**What**: Pre-built OpenClaw agent configurations (writer, critic, reviewer, planner, etc.) that can be applied when creating agents.

**Changes**:

- New type: `AgentTemplate = { id: Text, name: Text, description: Text, soulMd: Text, agentsMd: Text, defaultModel: Text, toolsProfile: Text, sandboxMode: Text }`.
- Templates stored as constants or in a persistent registry (start with constants, move to registry later).
- Tool handler: `list-templates-handler.mo`, used during agent creation.
- `create-agent-handler.mo` (or existing `register-agent-handler.mo`): accept optional `templateId` parameter.

**Verification**: Unit tests for template application.

---

## Phase D — Access Control & Agent Scoping

### D.1 — Agent Invocation Access Control

**What**: Define who can invoke an agent via `::` syntax based on channel scope.

**Changes**:

- `agent-model.mo`: Add `invocationScope: #membersOnly | #orgWide` to `AgentRecord`.
  - `#membersOnly`: agent only responds in workspace member/admin channels.
  - `#orgWide`: agent responds in any Slack channel.
- `events/agent-router.mo`: Before dispatching, check:
  - Resolve which workspace the agent belongs to.
  - If `#membersOnly`, verify the message channel is one of the workspace’s anchor channels.
  - If `#orgWide`, allow from any channel.
- Tool handler update: `update-agent-handler.mo` — allow setting `invocationScope`.

**Verification**: Unit test for routing guard with both scopes.

### D.2 — Workspace Ownership Clarification

**What**: Clarify that workspace admins are the owners of agents in that workspace and the paired gateway principal.

**Changes**:

- Documentation update in ARCHITECTURE.md.
- Enforce in tool handlers: only workspace admins can create/update/delete agents scoped to their workspace, manage codespace, push secrets.
- `agent-model.mo`: Add `workspaceId: Nat` field to `AgentRecord` — scopes the agent to a workspace.

**Verification**: Guard enforcement tests.

---

## Phase E — Future-Proofing

### E.1 — Cost Tracking Scaffolding

**What**: Add cost/usage tracking fields without implementing full cost optimization.

**Changes**:

- `agent-model.mo`: Add `usageStats: { totalPromptTokens: Nat, totalCompletionTokens: Nat, totalRequests: Nat, lastResetAt: Int }` to `AgentRecord`.
- OpenClaw webhook handler: accumulate tokens from agent responses into `usageStats`.
- Canister LLM calls: accumulate tokens from OpenRouter responses.
- No budgeting/alerting yet — just data collection for future phases.

**Verification**: Unit test for accumulation logic.

### E.2 — Agent Performance Metrics Scaffolding

**What**: Lay groundwork for the future "Head of Agentic HR" agent by storing performance data.

**Changes**:

- New fields on agent `toolsState`: `successRate`, `avgResponseTimeMs`, `lastNResults: [{ timestamp, tokensUsed, durationMs, feedbackScore: ?Int }]` (bounded circular buffer).
- This data is populated from OpenClaw webhook responses and canister LLM responses.
- No automated optimization yet — just collection.

**Verification**: Unit tests for circular buffer logic.

---

## Decisions

- **Two agent execution types**: `#api` (canister-hosted, calls LLM APIs directly) and `#runtime(#openClaw)` (runs remotely in codespace via OpenClaw). `AgentRouter` branches on execution type. Extensible for future runtime types.
- **One codespace per workspace** (not per agent) — OpenClaw handles multi-agent isolation natively via per-agent sandbox, workspace, and session separation. Much cheaper than one codespace per agent.
- **OpenRouter replaces Groq** as the canister’s LLM provider. Same model (`openai/gpt-oss-120b`), OpenAI-compatible API.
- **Anthropic keys are for OpenClaw agents only** — the canister itself uses OpenRouter exclusively.
- **Agent invocation scope** (not response visibility) — `#membersOnly` or `#orgWide` controls who can trigger an agent.
- **New webhook endpoints** (`/github/webhook`, `/openclaw/webhook`) break the "Slack-only write surface" invariant. This is intentional — GitHub and OpenClaw events cannot flow through Slack.
- **Express sidecar** in codespace for canister→OpenClaw communication, with HMAC-SHA256 auth.
- **v0.2 phases moved to PLAN.archive.md** — not absorbed into v0.3.
- **Excluded from v0.3**: Full cost optimization/budgeting, automated agent tuning (HR agent), A/B model testing, auth tokens/read surface, interactive Slack messages. These remain future work but v0.3 scaffolds the data collection.
- **Codespace machine type**: Default to cheapest 2-core. No admin override for now.
- **Sidecar secret rotation**: `rotate-sidecar-secret` tool handler, triggered by workspace admin. Generates new secret, pushes to sidecar, updates `CodespaceRecord`.
- **OpenClaw version pinning**: Codespace templates always use latest OpenClaw at creation time. When an agent is deployed, the running OpenClaw version is captured and stored in the agent’s config (`openClawVersion`). Pinned until explicitly upgraded. Sidecar health check returns version; canister logs mismatches but the version lives per-agent, not globally. Auto-update disabled on the instance.

---

## Relevant Files

**Core types + models**:

- `src/control-plane-core/types.mo` — SecretId, LlmProvider additions
- `src/control-plane-core/constants.mo` — Provider, secret, environment constants
- `src/control-plane-core/models/secret-model.mo` — Changelog, access log, #custom secrets
- `src/control-plane-core/models/agent-model.mo` — workspaceId, invocationScope, secretMappings, usageStats, templates, `AgentExecutionType` (#api | #runtime(#openClaw))
- New: `src/control-plane-core/models/codespace-model.mo`

**Wrappers**:

- `src/control-plane-core/wrappers/groq-wrapper.mo` → rename to `openrouter-wrapper.mo`
- New: `src/control-plane-core/wrappers/github-wrapper.mo`
- New: `src/control-plane-core/wrappers/sidecar-wrapper.mo`

**Events system**:

- `src/control-plane-core/events/slack-adapter.mo` — Refactor for multi-source webhook routing
- `src/control-plane-core/events/event-router.mo` — New event types + handlers
- New: `src/control-plane-core/events/github-adapter.mo`
- New: `src/control-plane-core/events/openclaw-adapter.mo`
- `src/control-plane-core/events/types/normalized-event-types.mo` — New event payload variants

**Agents + tools**:

- `src/control-plane-core/agents/admin/org-admin-agent.mo` — New codespace + config tools
- `src/control-plane-core/tools/tool-types.mo` — New tool resources
- New handlers under `src/control-plane-core/tools/handlers/`

**Services**:

- New: `src/control-plane-core/services/openclaw-config-service.mo`
- New: `src/control-plane-core/services/credential-resolver-service.mo`

---

## Verification

1. `icp build control-plane-core` after each phase.
2. `bun run tsc --noEmit` for TypeScript test code.
3. `mops test` for Motoko unit tests.
4. `bun run test:unit` + `bun run test:integration` for full test suite.
5. `RECORD_CASSETTES=true bun test <file>` for new integration tests requiring HTTP cassettes.
6. Manual: Trigger GitHub Device Flow, verify codespace creation, push OpenClaw config, receive agent response webhook.

---

## END of Archive — 5 April 2026

---

## Archive — 23 April 2026

Snapshot of a completed entry moved from the active plan.

---

## Plan: v0.5 — Entry Archive

### ~~5.0 — Remove Agent Forking~~

**Goal**

Delete the `fork_agent` feature entirely. It was designed for a workspace-cloning concept that is no longer part of the roadmap. Because forking was the only caller of `forkAgent` in `agent-model.mo`, the model function is removed along with the handler, tool registration, unit tests, and any cassette references. Agent configuration for new contexts will be handled through a different mechanism in a future phase.

**Current State**

- `AgentModel.forkAgent` exists in `models/agent-model.mo` (lines 381–427). It copies strategic config from an original agent into a new agent bound to a different workspace.
- `tools/handlers/agents/fork-agent-handler.mo` implements the LLM-facing handler (`fork_agent` tool).
- `tools/function-tool-registry.mo` imports the handler and registers `forkAgentTool` (guarded by `ar.write`).
- `tests/unit-tests/control-plane-core/test-canister.mo` imports the handler and exposes `testForkAgentHandler`.
- `tests/unit-tests/control-plane-core/tools/handlers/agents/fork-agent-handler.spec.ts` contains a full unit-test suite (15 test cases).
- `tests/cassettes/unit-tests/control-plane-core/events/handlers/message-handler/bot-branch-session-inherit.json` includes `fork_agent` in the serialised tool list sent to the LLM.
- `AGENTS.md` references `forkAgent` as a convention example.

**Desired State**

- `forkAgent` function removed from `agent-model.mo`.
- `fork-agent-handler.mo` deleted.
- All imports, registrations, and references to `fork_agent` / `forkAgent` removed from `function-tool-registry.mo`.
- `testForkAgentHandler` and its import removed from `test-canister.mo`.
- `fork-agent-handler.spec.ts` deleted.
- `fork_agent` removed from the cassette tool list in `bot-branch-session-inherit.json`.
- `AGENTS.md` convention example updated to remove the `forkAgent` reference.
- No compilation errors or failing tests.

**Source Steps**

1. `models/agent-model.mo` — Delete the `forkAgent` function and its doc comment.
2. `tools/handlers/agents/fork-agent-handler.mo` — Delete the file.
3. `tools/function-tool-registry.mo` — Remove the `ForkAgentHandler` import, the `List.add(tools, forkAgentTool(...))` call, and the `forkAgentTool` private function.
4. `tests/unit-tests/control-plane-core/test-canister.mo` — Remove the `ForkAgentHandler` import and the `testForkAgentHandler` public method.
5. `tests/unit-tests/control-plane-core/tools/handlers/agents/fork-agent-handler.spec.ts` — Delete the file.
6. `tests/cassettes/unit-tests/control-plane-core/events/handlers/message-handler/bot-branch-session-inherit.json` — Remove the `fork_agent` tool entry from the tool list array (appears at lines 16 and 36).
7. `AGENTS.md` — Update the model function parameter-order convention example to no longer cite `forkAgent`.
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- `mops test` passes with no references to `forkAgent`.
- `bun run tsc --noEmit` passes.
- `icp build control-plane-core` succeeds.
- Grep confirms zero occurrences of `forkAgent` / `fork_agent` across `src/` and `tests/`.

~~### 5.1 — Agent Channel Allowlist~~

**Goal**

Add a per-agent Slack channel allowlist (`allowedChannelIds`) to the agent model and enforce it in the `AgentRouter` before dispatching to any category service. When a message references an agent outside its allowed channels, the router blocks execution and posts an automatic warning to Slack. Each agent must be registered with at least one channel in its allowlist; the allowlist cannot be emptied after registration.

**Current State**

- `AgentRecord` has no `allowedChannelIds` field — agents respond to `::` references in any channel.
- `AgentRouter` checks execution type and category/context match but has no channel guard.
- ARCHITECTURE.md specifies: "The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution."

**Desired State**

- `AgentRecord` gains `allowedChannelIds : Set<Text>` — a set of Slack channel IDs where the agent is permitted to run. Must contain at least one channel; cannot be emptied after registration.
- `AgentRouter.route()` gains a pre-dispatch guard: if the message's channel ID is not in the agent's `allowedChannelIds` set, it posts an automatic Slack warning listing the allowed channels and skips execution (no category service dispatch).
- `register_agent` tool schema requires `allowedChannelIds` as a non-empty set of channel ID strings (input as array, converted to set). Mandatory at registration.
- `update_agent` tool schema includes `allowedChannelIds` as an optional set of channel ID strings. When provided, the new set must be non-empty (reject attempts to empty the allowlist).
- `get_agent` and `list_agents` tool responses include `allowedChannelIds`.

**Source Steps**

1. `models/agent-model.mo` — Add `allowedChannelIds : Set<Text>` to `AgentRecord`. Update `register` and `updateById`.
2. `tools/handlers/parsers/agent-parsers.mo` — Serialize/deserialize `allowedChannelIds` in agent JSON output.
3. `tools/function-tool-registry.mo` — Add `allowedChannelIds` to both `register_agent` (required, non-empty array) and `update_agent` (optional, non-empty array when provided) JSON schemas.
4. `tools/handlers/agents/register-agent-handler.mo` — Parse and pass `allowedChannelIds` (required; reject if missing or empty). Convert input array to set.
5. `tools/handlers/agents/update-agent-handler.mo` — Parse optional `allowedChannelIds` update. When provided, validate that the new set is non-empty (reject attempts to remove the last channel). Convert input array to set.
6. `tools/handlers/agents/get-agent-handler.mo`, `list-agents-handler.mo` — Include `allowedChannelIds` in output.
7. `events/agent-router.mo` — Add channel allowlist guard before the execution-type switch. The guard receives the Slack channel ID from the event context, checks it against `primaryAgent.allowedChannelIds`, and short-circuits with an error if not allowed.
8. **Migrate existing tests**: update every test helper or fixture that calls `register_agent` (or directly invokes `AgentModel.register`) to supply a non-empty `allowedChannelIds`. This includes `test-canister.mo` helper methods and all TypeScript integration test setup functions. Without this, all existing agent-creation calls will fail.
9. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (agent-model): register an agent with `allowedChannelIds` built via `Set.empty` + `Set.add` (for example, adding `"C123"`), confirm field persists. Update by adding `"C456"` with `Set.add`, confirm update. Attempt to create with empty set → error. Attempt to remove last channel → error.
- Unit test (agent-router): route a message from channel "C123" to an agent with `allowedChannelIds` built via `Set.empty` + `Set.add` containing `"C123"` → succeeds. Route from "C999" → blocked with error listing allowed channels. Attempt to remove the last channel → error (at least one required).
- Unit test (register-agent-handler): parse payload with valid `allowedChannelIds` (non-empty) → agent created. Parse payload with missing or empty `allowedChannelIds` → error.
- Integration tests: existing talk tests continue to pass after the migration in source step 8 — all agent-creation helpers and fixtures supply a non-empty `allowedChannelIds` matching the channel used in those tests.

---

~~### 5.1.2 — Cleanup of all Models and functions to use state params at start (and not end). Aligning with Motoko Compliance.~~

---

~~### 5.2 — Workflow Engines + Effect Applicator~~

**Goal**

Introduce the Workflow Engine abstraction — a clean boundary between _deciding what to execute_ (envelope construction), _executing it_ (engine dispatch), and _applying the results_ (effect application). Refactor the current inline LLM-loop-to-Slack-post pipeline into three phases:

1. **Envelope construction** — The orchestrator assembles a typed `ExecutionEnvelope`: fully assembled messages, instructions, execution constraints, and resolved credentials. The envelope is a data-only payload — it never contains code references, tool executors, or LLM wrappers. Think of it as the JSON body of an HTTP POST request.
2. **Engine dispatch** — The envelope is handed to the selected workflow engine. For `#internal` (this PR), the engine is a self-contained module that runs the multi-round LLM tool loop in-canister. The engine owns its own tool registry, LLM model selection, and execution strategy — the control plane does not dictate these. It returns a sealed `ExecutionPackage`: complete trace, final response, aggregated stats, and terminal status.
3. **Effect application** — The `EffectApplicator` receives the Package and executes all post-execution side effects: persisting traces, posting the Slack reply, finalizing the turn, and emitting follow-up events.

Only the `#internal` engine is implemented in this PR (in-canister LLM loop, mirroring the existing flow). The abstraction makes `#canister` and external engines pluggable in future PRs without touching the orchestrator or applicator.

**Current State**

- The LLM tool loop lives inside `org-admin-agent.mo` (`process()`) — it directly calls OpenRouter, executes tools, appends traces to the session model, and hands the response back to the message handler which posts the Slack reply.
- No separation between execution and side effects: LLM calls, tool calls, trace writes, and Slack posting are interleaved across the message handler and agent module.
- `config.workflowEngines` exists in the agent record but only `#canister` is functionally used, with no engine interface.
- `agent-orchestrator.mo` is a pass-through: scopes workspace data, decrypts secrets, delegates to the agent module.
- Context assembly (`context-assembler.mo`) and instruction composition (`instruction-composer.mo`) are coupled to the admin agent code path.

**Desired State**

- **`ExecutionEnvelope`** — Typed, self-contained, data-only input to any workflow engine:
  - `envelopeVersion : Nat` — schema version of this envelope format. The engine may reject envelopes it doesn't support and reply with the version it expects, enabling auto-corrective version negotiation.
  - `requestId : Text` — correlates the envelope to its package.
  - `agentId : Nat`, `agentName : Text`, `workspaceId : Nat`.
  - `workflowId : Text` — identifies which workflow the engine should execute (e.g., `"admin-v1"`, `"onboarding-v1"`). The engine advertises available workflow IDs via `availableWorkflows` in the Package; the control plane picks one per request. The engine owns what each workflow means (tools, model, strategy).
  - `messages : [ChatMessage]` — fully assembled context (session memory, channel history, user prompt).
  - `instructions : Text` — composed system prompt (all instruction layers merged).
  - `constraints : { maxRounds : Nat; maxTokenBudget : ?Nat }` — execution limits.
  - `secrets : { apiKeys : [(Text, Text)] }` — resolved credentials the engine needs (e.g., LLM provider API keys). For `#internal` these are static copies passed as params; for external engines they are serialized into the envelope payload.

  The envelope does **not** contain tool definitions, LLM model selection, or agent category. Those are the engine's responsibility — each `workflowId` encapsulates a specific combination of tools, model, and execution strategy managed entirely by the engine.

- **`ExecutionPackage`** — Typed, self-contained output from any workflow engine:
  - `packageVersion : Nat` — schema version of this package format. The control plane tracks the latest `packageVersion` received per engine so it knows which format to parse.
  - `requestId : Text` — matches the envelope's `requestId`.
  - `status : { #completed; #failed : Text; #roundLimitReached }`.
  - `response : ?Text` — final LLM text response (null if failed before any response).
  - `trace : [TraceEntry]` — complete ordered execution trace (every LLM call, tool call, decision point).
  - `stats : ExecutionStats` — `{ durationNs : Int; llmCalls : Nat; toolCalls : Nat; inputTokens : Nat; outputTokens : Nat; model : Text; rounds : Nat }`. Note: `model` is reported by the engine in stats (output), not dictated by the control plane (input).
  - `availableWorkflows : [Text]` — the engine's current catalog of supported workflow IDs. Included in **every** response (successful Package, rejection, error). The control plane updates its local catalog for this engine on every response received. This is the sole mechanism for catalog discovery — no pull/polling endpoint.

- **Engine interface** — `execute : (envelope) → async ExecutionPackage`. The `#internal` engine is a self-contained module: it owns its tool registry, LLM provider wrapper, and model selection logic per workflow. It receives only the envelope (a static data copy) and returns only the package (always including the current workflow catalog).

- **`EffectApplicator`** — `apply : (processingContext, package) → async Result<(), Text>`:
  - Persists `package.trace` entries to the session model (bulk write).
  - Posts `package.response` to Slack (threaded, with agent metadata).
  - Finalizes turn status and aggregates cost from `package.stats`.
  - Emits follow-up events if applicable (e.g., delegation triggers).

- **Envelope construction** uses `InstructionComposer` for layered system instructions and `ContextAssembler` for session + channel history context. The orchestrator assembles these into the envelope and selects a `workflowId` from the engine's cached catalog. Tool definitions and model selection are **not** in the envelope — the engine's workflow defines those.

- **Workflow catalog and A/B testing**:
  - Each engine advertises a catalog of `workflowId` strings — opaque IDs that each represent a specific execution configuration (tools, model, strategy) managed by the engine.
  - New workflow versions can coexist alongside old ones (e.g., `"admin-v1"` and `"admin-v1.1"`). The control plane can A/B test by routing a percentage of requests to the new version.
  - The catalog is refreshed **reactively**: every engine response (`ExecutionPackage`, rejection, error) includes `availableWorkflows` — the full current list. No polling or pull endpoint is needed.
  - When a workflow ID disappears from the catalog, the control plane stops sending it. When a new one appears, the control plane can start testing it.
  - For now, workflow IDs are opaque strings. Full metadata (description, capabilities, performance benchmarks) is deferred to a future "agent manager" service that calls a standard engine endpoint.
  - Over time, the control plane builds performance data per workflow (cost, latency, user satisfaction) and can shift traffic automatically — eventually training a classifier to pick the best workflow for each prompt.

- **HMAC / trust validation** scoped by engine type:
  - `#internal` (in-canister): no signing needed — the Package never crosses a trust boundary.
  - `#canister` (future): caller principal validation — the control plane verifies `msg.caller` matches the expected engine canister ID.
  - External HTTP engines (future): HMAC-SHA256 on the package payload with a pre-shared secret between the control plane and the external engine instance.

- **Envelope/Package version negotiation**:
  - The control plane tracks, per workflow engine, the latest `envelopeVersion` it sends and the latest `packageVersion` it has received.
  - If an external engine rejects an envelope (e.g., schema too old or too new), it replies with the `envelopeVersion` it expects in the rejection body. The control plane records this and retries with the requested version. This allows engines to evolve independently — different engines can be at different envelope versions at the same time.
  - Similarly, the `packageVersion` field in every Package tells the control plane which schema to use for parsing. The control plane maintains parsers for all supported versions.
  - For `#internal`, version negotiation is compile-time — the engine and control plane share the same type definitions and always agree.

**Design Notes**

- **The `#internal` engine is pure.** Only `main.mo` owns the persistent data structures. The envelope is assembled from static copies of state (messages, instructions, credentials) and passed as params to the engine. Since the engine receives copies — not references to `main.mo`'s data — any mutations the engine makes to its local params do not affect the canister's persistent state. All persistent side effects flow exclusively through the Effect Applicator after the engine returns the Package. This is the same guarantee an external engine provides by design (it can't reach the canister's state), achieved here through Motoko's value semantics.
- **The engine owns tools, model selection, and execution strategy via workflows.** The control plane tells the engine _what_ to do (instructions, context, constraints) and _which workflow_ to use (`workflowId`). The engine decides _how_ that workflow executes: which LLM to call, which tools to register, how to orchestrate the loop. For `#internal`, each workflow ID maps to a specific tool set + model combination. This means the tool registry, tool executor, and LLM wrapper live inside the engine module — they are not imported from the core codebase by the orchestrator.
- **Workflow versioning enables safe evolution.** An engine can introduce `"admin-v1.1"` alongside `"admin-v1"` without any control plane changes. The control plane sees the new ID in `availableWorkflows`, starts A/B testing, and gradually shifts traffic based on observed performance (cost, speed, user reviews). When the old version is retired, the engine drops it from the catalog and the control plane stops using it. No coordinated deploys, no breaking changes.
- **No trace mitigation needed for mid-execution traps.** If the engine traps (e.g., an HTTP outcall fails), local state from that IC message is rolled back and no Package is returned. From the Effect Applicator's perspective, no Package means no effects applied — the turn was never updated. The control plane's trace will show "envelope sent" (the dispatch happened) but no package received. Each workflow engine is responsible for its own internal logging; the control plane does not attempt to recover partial engine state.
- **The Package is the atomic observability unit.** Every LLM call, tool call, and decision is captured in `package.trace`. The applicator uses this to build the Slack thread trace (the primary human-facing audit log). No separate trace-writing path exists outside the applicator.
- **Engine selection is trivial in this PR.** Only `#internal` exists. The orchestrator selects based on `agent.config.workflowEngines[0]`, and uses the only available workflow from the engine's catalog. Future PRs add engine selection logic and workflow-level A/B testing.
- **Envelope construction owns all context assembly.** The envelope contains fully assembled messages — the engine never reaches back into session model or channel history. This makes the engine portable: the same `#internal` engine implementation works regardless of what assembled the envelope, and a future external engine receives a self-contained payload.
- **No `EngineContext` — the engine is fully self-contained.** The `#internal` engine module contains its own tool registry, tool executor, and LLM wrapper. It does not import these from the core codebase. The envelope carries everything the engine needs as data (messages, instructions, constraints, secrets, workflowId). For external engines, this is natural (the envelope is a POST body). For `#internal`, this means the engine module is a self-contained folder with no imports from `tools/`, `services/`, or `wrappers/` — only from `types/execution.mo` for the shared Envelope/Package types.
- **Versioned envelope and package formats.** `envelopeVersion` and `packageVersion` enable independent evolution of the control plane and its engines. An engine can reject an envelope version it doesn't support and tell the control plane which version to send. The control plane can parse any `packageVersion` it has seen. For `#internal` this is compile-time agreement; for external engines it enables rolling upgrades without coordinated deploys.

**Source Steps**

1. New file: `types/execution.mo` — `ExecutionEnvelope` (with `envelopeVersion`, `workflowId`), `ExecutionPackage` (with `packageVersion`, `availableWorkflows`), `ExecutionStats`, `PackageStatus`, `ExecutionConstraints` types. Minimal, no behavior — pure type definitions shared between the orchestrator and all engines.
2. New directory + file: `engines/internal/internal-workflow-engine.mo` — `execute(envelope) → async ExecutionPackage`. Self-contained module with its own tool registry, tool executor, and LLM wrapper (OpenRouter). No imports from `tools/`, `services/`, or `wrappers/`. Reads `envelope.workflowId` to select the tool set + model. Calls OpenRouter, handles `#toolCalls`, accumulates traces in a local buffer, iterates up to `constraints.maxRounds`, seals the Package (including `availableWorkflows`) on completion/failure/round-limit. Initial workflows: `"admin-v1"` (admin tool set), `"onboarding-v1"` (stub, returns not-yet-implemented).
3. New file: `services/effect-applicator.mo` — `apply(processingContext, package) → async Result<(), Text>`. Writes `package.trace` to session model. Posts `package.response` to Slack via `SlackWrapper.postMessage`. Updates turn status (`#completed`/`#failed`) and cost aggregates. Emits follow-up events if needed.
4. Refactor `orchestrators/agent-orchestrator.mo` — Replace the direct `adminAgent.process()` call with: (a) assemble `ExecutionEnvelope` (context + instructions + constraints + secrets + workflowId from cached catalog), (b) dispatch envelope to selected engine, (c) update local workflow catalog from `package.availableWorkflows`, (d) pass Package to Effect Applicator.
5. Refactor `agents/admin/org-admin-agent.mo` — Transform `process()` into envelope assembly logic that returns an `ExecutionEnvelope`. What remains in the orchestrator path: instruction composition via `InstructionComposer`, context assembly via `ContextAssembler`, secret resolution, workflow selection from cached catalog. Tool assembly and LLM wrapper move into the `#internal` engine module.
6. Refactor `events/handlers/message-handler.mo` — Slack reply posting moves to the Effect Applicator (called through the orchestrator). The handler delegates to the orchestrator and receives the final result, no longer posts directly.
7. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (execution): construct Envelope and Package values, verify all fields are correctly typed and accessible.
- Unit test (internal-workflow-engine): mock LLM to return `#textResponse` → Package has `#completed` status with response. Mock LLM to return `#toolCalls` then `#textResponse` → Package trace contains both `#llmCall` and `#toolCall` entries in order. Mock LLM to loop `maxRounds` times → Package has `#roundLimitReached` status. Mock LLM to error → Package has `#failed` status with error message. Verify engine selects tools and model based on `workflowId` without external input. Verify `availableWorkflows` is always populated in the Package.
- Unit test (workflow catalog): send envelope with unknown `workflowId` → engine returns `#failed` with error + `availableWorkflows` listing valid IDs. Send envelope with valid `workflowId` → Package includes full `availableWorkflows` catalog.
- Unit test (effect-applicator): given Package with N trace entries → all N entries written to session model. Given Package with response text → `SlackWrapper.postMessage` called with correct channel/thread/content. Given Package with `#failed` status → turn marked as failed.
- Unit test (purity): pass an envelope to the engine, verify that the original envelope data is unchanged after execution (static copy guarantee).
- Integration test: full flow from Slack message → envelope build → `#internal` engine → Package → Effect Applicator → Slack reply + persisted session trace. Verify the Slack reply content and session trace entries match the execution.
- Regression: all existing admin-talk integration tests pass with no behavioral change (pipeline restructured, user-visible output identical).

---

## END of Archive — 23 April 2026

---
