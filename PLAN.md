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

12. **Verify** — `dfx build open-org-backend --check` — no compilation errors.

**Test Steps**

_Unit tests — new file `tests/unit-tests/open-org-backend/agents/planning/work-planning-agent.test.mo`_:

- **Category-to-role**: `#planning` → `#customAgent` with `"work planning specialist"` persona.
- Existing planning-domain tool-filtering and instruction-building tests ported here.

_Unit tests — updated `tests/unit-tests/open-org-backend/agents/admin/org-admin-agent.test.mo`_:

- **No planning tools in tool set**: `list_workspaces` is present; `save_value_stream` is absent.
- **`buildInstructions`**: no value-stream or metrics blocks; org-admin persona block present.
- **`create_workspace` tool**: call handler with `"My Team"` → workspace created in `WorkspacesState`.
- **`list_workspaces` tool**: two pre-seeded workspaces → tool returns both records.
- **`set_workspace_admin_channel` tool**: sets `adminChannelId` on the target workspace.
- **`get_org_admin_channel` tool**: reads workspace 0's `adminChannelId`; returns null when unset, returns the channel ID when set.

_Unit tests — updated `tests/unit-tests/open-org-backend/events/agent-router.test.mo`_:

- **`#admin` category + `#admin` ctx → dispatches to org-admin agent** (orchestrator stub returns `#ok`).
- **`#planning` category + `#planning` ctx → dispatches to work-planning agent**.
- **Category/ctx mismatch** (e.g. `#admin` category with `#planning` ctx) → `#err("agent context mismatch")`.
- **`#research` → `#err("category not implemented")`**.
- **`#communication` → `#err("category not implemented")`**.

_Integration tests — updated `tests/integration-tests/open-org-backend/workspace-admin-talk.spec.ts`_:

- Existing planning-flow tests migrated to register a `#planning` agent; all assertions unchanged.
- **New — org-admin workspace list**: register a `#admin` agent; send `"list my workspaces"` → `list_workspaces` step appears; response enumerates workspace names.
- **New — org-admin create workspace**: register a `#admin` agent; send `"create a workspace called Ops"` → `create_workspace` step appears; canister state reflects the new workspace.

---

## Phase 2 — Slack-Only Write Surface

**Goal**: Ensure all mutations enter through Slack events. Remove any remaining update call endpoints exposed to external clients.

### 2.1 - Add tests to all handlers (see main.mo / integration tests for many of this logic)

- ?

### 2.2 — Audit and remove external update methods

- Review all `public shared` methods in `main.mo`.
- Migrate one domain (notice the comments saying something like "XYZ Management") at a time to be a tool in registry, with respective handler and test.
- Remove or gate any `update` method that isn't `http_request_update`.
- Ensure `http_request` (query) and `http_request_update` are the only entry points.

### 2.3 — Session tracking model

- New persistent model: `Map<slackMessageId, SessionRecord>`.
- `SessionRecord = { sessionId, slackMessageId, userAuthContextId, agentId, parentSessionId }`.
- `sessionId` format: `{agent_name}_{user_id}_{unique_incremental_id}`.
- `parentSessionId`: links to the session that triggered this one (forms delegation chain).
- Support delegation chain reconstruction by walking `parentSessionId` links.
- Retention policy: bounded by time or count (TBD).

### 2.4 — Access scoping on models

- Add visibility metadata to models: `read: #org | #team | #admin`, `write: #org | #team | #admin`.
- Enforce at the service level: check `userAuthContext.workspaceScopes` (and `isOrgAdmin` for org-level resources) against the resource's required level before read/write operations.
- Examples: objectives (`read: org`, `write: admin`), tasks (`read: org`, `write: team`).

### 2.5 — App install and setup flow

- On canister init or first Slack event: call `conversations.list` + `users.list`.
- Identify Primary Owner (`is_primary_owner: true`).
- Detect or request creation of `#looping-ai-org-admins`.
- Store channel ID anchor. Populate org admin user cache entries.

### 2.6 — Remove legacy auth

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
