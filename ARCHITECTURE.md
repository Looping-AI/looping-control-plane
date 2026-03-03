# Architecture

This is a living document. It focuses on design intent, invariants, rationale, and links to code for implementation details.

## Purpose

This repo is meant to be forked and adapted to personal or organizational use.
The long-term goal is an autonomous agent system that behaves like a teammate or coach: it can ingest requests and events, plan work, run tasks via tools/LLMs, measure impact against goals, and manage cost trade-offs.

This is a **strongly opinionated framework** focused on **Slack as the primary user experience layer**. By inheriting Slack's user management, channel-based permissions, and event-driven security model, the system gains easier onboarding, a more robust security posture, and a simpler authorization model compared to implementing custom user management.

## Reading Guide

Read until "Core Flows" for a high-level view of what exists today and where the design is headed. After that, the document becomes more technical and is most useful when you're changing or debugging a specific subsystem (timers, encryption, wrappers, or tests). "Deep Dives" links you directly to the implementation files for quick reference.

## Key Goals

- Keep a small, understandable core that forks can extend.
- Make authorization and policy explicit at the controller and data classes layers.
- Make long-running work asynchronous via queued tasks (avoid doing heavy work inside request handlers).
- Track impact and cost with enough structure to support later attribution and budgeting.
- Be safe-by-default: secrets encrypted at rest, full verification of event sources, conservative tool access.
- Slack-first: all write operations originate from Slack; all read operations are gated by short-lived, resource-based auth tokens.

## Non-Goals (for now)

- Consolidated org billing and complex cost sharing.
- Multi-canister "enterprise" topology (root/main/frontend) as a requirement.
- Guaranteed perfect autonomy; humans remain in the loop via goals, policies, and approvals.
- Comprehensive compliance/regulatory features (these can be fork-specific).

## System Overview

### Current implementation (today)

- Single Motoko backend canister receiving Slack events via `http_request` / `http_request_update`.
- Slack event adapter with HMAC-SHA256 signature verification and event normalization.
- Event store with lifecycle management (unprocessed → processed/failed) and per-event timer dispatch.
- Event router dispatching to handlers (message handler fully implemented, others stubbed).
- Workspace admin orchestrator calling a Groq-based LLM service with function tools.
- Tool infrastructure: static function tool registry (resource-gated) and dynamic MCP tool registry.
- Metrics, value streams, and objectives models (org-level metrics, workspace-scoped value streams/objectives).
- API keys and secrets encrypted at rest using workspace-scoped derived keys (ICP Threshold Schnorr).
- LLM provider integration via HTTP outcalls (currently Groq).

Primary code entrypoint: [src/open-org-backend/main.mo](src/open-org-backend/main.mo)

### Target direction (what this architecture file plans for)

- Slack as the exclusive write surface: all mutations flow through Slack events or Slack API calls.
- Read-only external access via resource-based, short-lived (1h) auth tokens generated within the canister.
- Identity and authorization fully derived from Slack: user cache mirroring Slack members, roles derived from channel membership.
- Workspace model with channel-based scoping: each workspace maps to an admin channel and a member channel.
- Agent registry with `::` reference syntax enabling agent-to-agent delegation through Slack messages.
- Agent Router dispatching to category-specific agent services, each with scoped tools and skills.
- Session tracking linking Slack message IDs to user auth context and agent execution state.
- Interactive Messages (block actions, view submissions) for configuration and onboarding flows.

## Architecture Principles

- Separation of concerns:
  - Controller layer: authentication/authorization/validation, policy checks, and orchestration.
  - Services: deterministic state transitions and reusable business logic.
  - Wrappers: encapsulation of external calls (LLMs/APIs), so integration changes and cross actions live in one place.
- Slack-first security: all write operations must originate from Slack events, which carry Slack's own authentication guarantees. The canister never trusts a write that doesn't come through a verified Slack event.
- "Plan fast, execute later": request handlers should enqueue tasks instead of running long operations.
- LLMs will use Policies, Tools and Knowledge as a flexible way to execute tasks, and will only code them as they become more frequent and easier to standardize.
- Have explicit approval flows, guard-rails, for context control, without micro-managing (tool access, spending limits, any other custom approval defined in a Policy).
- Mixture of agents is desired as a strategy (Lower input/context window, easier A/B testing for cost/quality optimizing, lower risk on model upgrading).
- Auditable: the system should be auditable (events, session tracking, and conversation history).
- Avoid LLM Obedience: be resilient to prompt injection and spoofed events (Through Slack signature verification, data classes, and policies).
- Agent isolation: an agent service must never directly invoke another agent service. Inter-agent communication always flows through a Slack `postMessage` that triggers a new event, ensuring every hop is auditable and budget-checkable.

## Core Concepts

### Workspace

A unit of policy, goals, knowledge, and shared state. Each workspace maps to:

- `id`: unique numeric identifier (0 = the org workspace, always exists).
- `name`: human-readable name.
- `adminChannelId`: Slack channel ID whose members are workspace admins.
- `memberChannelId`: Slack channel ID whose members are workspace members.

### User Auth Context

The resolved identity and permissions of the user who initiated a request. Built from the Slack user cache at event-processing time and passed into all agent services. Contains:

- `slackUserId`: the Slack user ID.
- `isPrimaryOwner`: whether this user is the Slack Primary Owner.
- `isOrgAdmin`: whether this user is a member of `#looping-ai-org-admins`.
- `workspaceScopes`: per-workspace access level — `Map<workspaceId, #admin | #member>`. Only contains workspaces where the user has membership.
- `roundCount`: how many agent routing rounds have occurred for this request chain.
- `forceTerminated`: whether the router has determined this chain should stop.

The `userAuthContext` is the single source of truth for authorization in all downstream operations. It is carried through agent delegations: when agent A references agent B (on a Slack Message), the `userAuthContext` of the original human user is inherited, not the agent's identity.

### Session

A tracking record linking a Slack message to its processing context. Created when the handler picks up the task from the queue and updated when the bot sends a reply via `postMessage` (and a slackMessageId is obtained).

- `sessionId`: format `{agent_name}_{user_id}_{unique_incremental_id}`.
- `slackMessageId`: the Slack `ts` identifier of the bot's reply message (used as the map key once available).
- `userAuthContextId`: reference to the `userAuthContext` that authorized this session.
- `agentId`: which agent handled this session.
- `parentSessionId`: if this session was triggered by another agent's message, the parent session. Forms the delegation chain — the full history can be rebuilt by walking `parentSessionId` links.

### Agent

A named, configurable entity that uses an LLM with specific tools and skills. Agents are registered in a persistent agent registry and referenced via the `::` syntax in Slack messages.

### Agent Category (Service)

A class of agent behavior (e.g., admin, research, communication, coding). Each category defines:

- `category_tools`: the set of tool enum variants available to agents in this category.
- LLM model selection strategy.
- Template Skills and source/knowledge configuration.

### Policies

Text-based rules governing what is allowed or not. Applied at the workspace level to constrain tasks, tools, budgets, and permissions. From these text based documents, logic rules are captured and converted into Dynamic Logic, formal logic, rules. Then they should be upheld when accessing tools. Maybe consider using an adaptation of Cedar Policy framework https://github.com/cedar-policy/cedar-authorization.

### Events

Normalized inbound signals derived from Slack Events.
All system state mutations are driven exclusively by Events (or internally scheduled Tasks).
Any external trigger or integration must flow through Slack first, using its native integration mechanisms, resulting in Slack-originated messages.
This ensures all actions inherit Slack’s existing Admin and App-level controls, never through direct access.

### Tasks

Queued work items that may involve awaits (LLM calls, tool use, function calling). Executed asynchronously by the task runner.

## External Interfaces

### Write Surface — Slack Only

All write operations enter the canister exclusively through Slack:

- **Slack Events API** (`http_request_update`): messages, app mentions, channel membership changes, interactive message callbacks.
- **Slack API** (outbound HTTP outcalls): the canister calls Slack to post messages, read user lists, and read channel memberships.

No canister `update` methods are exposed for external clients. The Slack event signature verification (HMAC-SHA256 with timestamp replay protection) is the authentication layer for all writes.

### Read Surface — Token-Gated Queries

All external read access requires a **resource-based, read-only, short-lived (1h) auth token**:

- Tokens are generated inside the canister, triggered by a Slack command from the user.
- Token generation is logged for any future access audit.
- Each token maps to `{ slackUserId, isOrgAdmin, workspaceScopes: Map<workspaceId, #admin | #member>, resourceScope, expiry }`.
- Query methods validate the token, check expiry, and return scoped data.
- Token storage is persistent, short-lived (1h) and cleaned up on a weekly Timer.
- No sensitive or personal data is exposed — only aggregated stats and summaries scoped to the token's access level.

This design aligns with security best practices: short-lived tokens, server-side generation, logged access, and minimal data exposure.

### Interactions

- **Slack** (primary, implemented): Events API, Web API (`postMessage`, `users.list`, `conversations.list`, `conversations.members`).
- **Slack Interactive Messages** (planned): `block_actions` and `view_submission` payloads for configuration and onboarding UX.

## Core Flows

### Slack event processing (current)

1. Slack sends an event to `http_request_update`.
2. `SlackAdapter` verifies the HMAC-SHA256 signature (with timestamp replay protection).
3. `SlackAdapter` parses the raw JSON into typed structures and normalizes into an internal `Event`.
4. `EventStoreModel` enqueues the event (dedup check across all maps).
5. A `Timer.setTimer(#seconds 0)` fires `EventRouter.processSingleEvent`.
6. The router claims the event, dispatches to the appropriate handler.
7. The handler executes (e.g., calls LLM via orchestrator, posts reply to Slack).
8. Event is marked as processed or failed.

### Agent talk flow (current)

1. Message handler receives a normalized message event.
2. Scopes workspace data, derives encryption key, decrypts secrets.
3. Calls `WorkspaceAdminOrchestrator` → `GroqWorkspaceAdminService`.
4. Multi-turn LLM conversation loop (up to 10 iterations) with function tool calling.
5. Posts reply to Slack via `SlackWrapper.postMessage` (threaded if original was threaded).

### Agent-to-agent delegation (planned)

1. User sends `@looping ::accounting deliver me a report on last financials`.
2. Event router resolves `::accounting` from the agent registry, builds `userAuthContext` from `SlackUserModel` (the Slack user cache).
3. `::accounting` agent service processes the request, determines it needs data from `::tech`.
4. `::accounting` posts a Slack message referencing `::tech` (architectural invariant: never call another agent service directly).
5. That message triggers a new Slack event → event router picks it up.
6. Router reconstructs the `userAuthContext` from the parent session (including incremented `roundCount`), creates a new session with `parentSessionId` linking to the previous one.
7. `::tech` processes with the original user's access scopes but its own tools/skills.
8. `::tech` replies → new event → router returns control to `::accounting`.
9. `::accounting` compiles the report and replies to the original user.
10. If sensitive data was accessed at a higher level than the channel allows, the bot sends a generic acknowledgement in the original channel and delivers the detailed reply in the user's DM or the appropriate scoped channel.

### Token generation flow (planned)

1. User sends a DM to the bot requesting access (e.g., a command or prompted text).
2. Bot resolves user's `userAuthContext` from the Slack user cache.
3. Bot generates a resource-based, read-only token inside the canister using the resolved `SlackUserEntry`. Stores `{ slackUserId, isOrgAdmin, workspaceScopes: Map<workspaceId, #admin | #member>, resourceScope, expiry: now + 1h }`.
4. Bot replies in the DM with the token (or a link containing it).
5. External client (frontend) uses the token to call query methods.
6. Frontend may provide an easy-to-copy Slack prompt so users can request new tokens when they expire.

### App install and setup flow (planned)

1. On install, the bot calls `conversations.list` and `users.list` via SlackWrapper.
2. Identifies the Primary Owner from: the user in `users.list` with `is_primary_owner: true`.
3. Checks if a channel named `#looping-ai-org-admins` exists.
   - If yes: stores its **channel ID** as the org admin channel anchor. Populates org admin list from channel members.
   - If no: sends a DM to the Primary Owner requesting creation of the channel.
4. Weekly reconciliation verifies the org admin channel: channel ID still exists and name still matches.
   - Same ID, renamed → flag but don't break (notify Primary Owner to confirm).
   - ID gone → recovery mode (DM to Primary Owner).
   - Different ID now but has the name → suspicious, recovery mode (DM to Primary Owner).
5. From the `#looping-ai-org-admins` channel, admins set up workspaces via interactive messages.

### Workspace onboarding (planned)

1. An org admin in `#looping-ai-org-admins` requests to create a new workspace.
2. Bot presents an interactive message: workspace name, selection of channels (public or private where bot has access) for admin and member channels, or manual channel ID entry.
3. If the selected channel is not accessible, the bot guides the user to run `/invite @looping` in that channel first.
4. Bot creates the workspace record and populates the user cache with the channel members' roles.

## State Model

### Current persistent state

See [src/open-org-backend/main.mo](src/open-org-backend/main.mo).

- `orgOwner` / `orgAdmins`: Principal-based ownership (to be replaced by Slack-derived identity).
- `workspaceAdmins` / `workspaceMembers`: per-workspace Principal arrays (to be replaced by Slack-derived role membership in Phase 0).
- `agentRegistry`: global agent registry with dual index by ID and name (Phase 1.1, implemented).
- `conversationStore`: channel-keyed, timeline-structured message history with 1-month ts-based retention (Phase 1.4, implemented). Replaces old `conversations` / `adminConversations` workspace-keyed maps. Round tracking is embedded here — each `ConversationMessage` carries a `userAuthContext` field (`roundCount`, `forceTerminated`) so no separate round-context store is needed. See [src/open-org-backend/middleware/slack-auth-middleware.mo](src/open-org-backend/middleware/slack-auth-middleware.mo) for the `UserAuthContext` type.
- `slackUsers`: Slack user cache (`SlackUserEntry` records indexed by Slack user ID); populated by event-driven membership events and weekly reconciliation.
- `workspaces`: workspace channel anchors (`WorkspaceRecord` indexed by workspace ID, each with `adminChannelId` / `memberChannelId`).
- `orgAdminChannel`: optional anchor for the `#looping-ai-org-admins` Slack channel.
- `secrets`: encrypted secrets per workspace.
- `mcpToolRegistry`: dynamic MCP tool registry.
- `metricsRegistry` / `metricDatapoints`: org-level metrics.
- `workspaceValueStreams` / `workspaceObjectives`: workspace-scoped value streams and objectives.
- `eventStore`: event lifecycle (unprocessed/processed/failed).
- `httpCertStore`: HTTP certification state.

### Target persistent state

- **Workspaces**: `Map<workspaceId, WorkspaceRecord>` where `WorkspaceRecord = { id, name, adminChannelId, memberChannelId }`.
- **Slack user cache**: `Map<SlackUserId, SlackUserEntry>` where `SlackUserEntry = { slackUserId, displayName, isPrimaryOwner, isOrgAdmin, workspaceMemberships: [(workspaceId, #admin | #member)] }`. Backed by `SlackUserModel`.
- **Org admin channel**: `{ channelId, channelName }` (the anchor for `#looping-ai-org-admins`).
- **Agent registry**: `AgentRegistryState = { nextId, agentsById: Map<Nat, AgentRecord>, agentsByName: Map<Text, Nat> }` where `AgentRecord = { id, name, category, llmModel, secretsAllowed: [(workspaceId, SecretId)], toolsAllowed, toolsState: Map<Text, ToolState>, sources }`. Dual-index for O(1) lookup by ID or name. File: [src/open-org-backend/models/agent-model.mo](src/open-org-backend/models/agent-model.mo).
- **Session store**: `Map<slackMessageId, SessionRecord>` for tracking agent execution across delegation chains.
- **Auth token store**: `Map<tokenId, TokenRecord>` with `{ slackUserId, isOrgAdmin, workspaceScopes: Map<workspaceId, #admin | #member>, resourceScope, expiry }`. Cleaned up on Sundays in a Timer.
- **Secrets**: encrypted secrets per workspace (existing, retained).
- **Conversations**: channel-keyed, timeline-structured persistent store (Phase 1.4, implemented). Each channel has posts and threads indexed by Slack timestamp, with 1-month ts-based retention. See [src/open-org-backend/models/conversation-model.mo](src/open-org-backend/models/conversation-model.mo) for the `ConversationStore` structure: `Map<channelId, ChannelStore>` where `ChannelStore = { timeline: Map<ts, TimelineEntry>, replyIndex: Map<ts, rootTs> }`. `TimelineEntry` is either a `#post` (top-level message) or `#thread` (root + replies). Messages carry `userAuthContext` (null for bot replies, set for user messages) enabling LLM role mapping without additional lookups. Tool call/response artifacts are ephemeral (in-memory only, not persisted) pending Phase 1.7 session tracking.
- **Event store**: event lifecycle with timer dispatch (existing, retained).
- **Metrics / Value Streams / Objectives**: existing models retained.
- **Tool registries**: function tool registry (static) and MCP tool registry (dynamic), with new per-agent `toolsAllowed` and `toolsState`.

### Transient state

- Key-derivation cache (cleared periodically, re-derived on demand).

## Identity, Roles, and Authorization

### Slack-derived identity

The canister does not manage its own user accounts. All identity is derived from Slack:

- **Primary Owner**: the Slack user with `is_primary_owner: true` in `users.list`. Has ultimate administrative authority. Recovery flows (e.g., lost org admin channel) are directed to this user via DM.
- **Org Admin**: a member of the `#looping-ai-org-admins` channel, identified by channel ID.
- **Workspace Admin**: a member of a workspace's designated admin channel.
- **Workspace Member**: a member of a workspace's designated member channel.

### SlackAuthMiddleware

Replaces the current Principal-based `AuthMiddleware`. At event-processing time:

1. Extracts the Slack user ID from the event payload.
2. Looks up the user in the Slack user cache.
3. Resolves their access level and workspace scopes.
4. Builds a `UserAuthContext` that is passed to all downstream services.

All authorization decisions are based on the `UserAuthContext`, not on IC caller Principals.

### User cache synchronization

**Real-time (event-driven, primary):**

- `member_joined_channel` → add user to the workspace's role set.
- `member_left_channel` → remove user from the workspace's role set.
- `team_join` → add user to the cache with default (no workspace) membership.

**Weekly reconciliation (Sundays, fallback):**

- Full `users.list` + `conversations.members` sweep for all tracked channels.
- Corrects any drift from missed events.
- Also verifies all tracked channel IDs still exist:
  - **Org admin channel**: follows its own recovery rules (see "App install and setup flow").
  - **Workspace admin channel gone**: notify `#looping-ai-org-admins`, request that an org admin assigns a new admin channel or requests workspace deletion.
  - **Workspace member channel gone**: notify that workspace's admin channel, request that a workspace admin assigns a new member channel.

### Access scoping on models and tools

Resources have read/write visibility levels: `org`, `team`, `admin`.

Model examples:

- Objectives: `read: org`, `write: admin`.
- Tasks: `read: org`, `write: team`.

Tool examples:

- `web_search`: team access.
- `mcp_send_social_post`: team access.
- `mcp_send_job_opening`: admin access.

No individual access configuration is allowed. If truly needed, the org admin can create a workspace with only that individual and explicitly assign the desired resources and tools.

### Access level resolution

The access level is always determined by the **user** who wrote the original message, regardless of which channel the message was sent in. When an agent replies:

- If the reply contains data that required a higher access level than the current channel's scope, the bot sends a **generic safe acknowledgement** in the original channel.
- The **detailed reply** is delivered in the user's DM, or the appropriate scoped channel (admin channel or member channel).
- This split-reply behavior is determined after the LLM generates its response, by inspecting the processing steps to see if a higher scope was accessed.

## Agent System

### Agent registry

Agents are stored in a persistent registry with dual indexes (`agentsById: Map<Nat, AgentRecord>`, `agentsByName: Map<Text, Nat>`) for O(1) lookup by ID or name. Each agent record (`AgentRecord`) has:

- `id`: stable unique numeric identifier, assigned by the registry on registration.
- `name`: kebab-case identifier, must be unique and match the `::name` syntax. Stored lower-cased; lookups are case-insensitive.
- `category`: which agent category/service handles this agent (e.g., `#admin`, `#research`, `#communication`).
- `llmModel`: the LLM provider and model to use (e.g., `#groq(#gpt_oss_120b)`).
- `secretsAllowed`: explicit whitelist of `(workspaceId, SecretId)` pairs this agent is permitted to access. The agent service must check this list before decrypting any secret.
- `toolsAllowed`: subset of the category's `category_tools` that this agent is permitted to use.
- `toolsState`: per-tool runtime state (`Map<Text, ToolState>`):
  - `usageCount`: how many times this tool has been invoked by this agent.
  - `knowHow`: a Text field containing tool-specific operational knowledge — configuration state, secret key references (how to find them in Secrets), good/bad practices, documentation links, and other relevant context. This field is also used when duplicating an agent as a template: the know-how can be copied and adapted.
- `sources`: knowledge sources and context configuration.

### `::` reference syntax

Users (or agents) reference agents in messages with the `::` prefix notation.

**Trigger**: `::agentname`

**Regex**: `(?<!\\)(?<!\w)::([a-z][a-z0-9-]*)`

**Ignored contexts**: inline code, code blocks, escaped `\::agent`.

**Validation**: the name must exist in the agent registry. Case-insensitive matching.

When an agent is referenced, the access scope remains that of the original user. The agent uses its own skills and tools, but scoped to the original user's `userAuthContext`.

### Agent categories and services

Each agent category defines a service class that handles execution:

- `category_tools`: an array of tool enum variants available to agents in this category. This type structure is also used when configuring agent tool permissions through Slack interactive components.
- LLM model selection strategy.
- Skills and knowledge configuration.

**Phased implementation:**

- **Phase 1**: Agent registry, `::` routing, single generic agent service (refactor of current `GroqWorkspaceAdminService`).
- **Phase 2**: Split into 2–3 specialized services based on real usage patterns.
- **Phase 3**: Full pluggable agent framework. Each phase is a separate development effort (different PRs).

### Agent routing and round control

The **Agent Router** sits between the event router and agent services.

**Pre-conditions (checked before routing begins):**

- The message must contain at least one **valid `::agentname` reference** — resolved against the agent registry at dispatch time. If no valid reference is found (e.g., the reference doesn't match any registered agent), the event is **discarded/skipped**. This prevents orphaned or malformed inter-agent messages from entering the routing loop.
- `userAuthContext.forceTerminated` must be `false`. If true, the event is **discarded/skipped** without invoking any agent service.

Both conditions are checked at the event router level, before the Agent Router hands off to a category service.

When a message passes pre-conditions and references an agent:

1. Resolves the agent from the registry.
2. Selects the appropriate category service.
3. Passes the `userAuthContext` and session context to the service.
4. The service executes and posts a reply to Slack.

**Round tracking** (in `userAuthContext`):

- `roundCount` increments each time the router processes a new event in the same request chain.
- **Hard upper bound**: `MAX_AGENT_ROUNDS` (10, defined in Constants). Once this limit is reached, the session is force-terminated.
- **Dynamic controls**:
  - If the reply at round N is very similar to round N-1, the router sets `forceTerminated: true` on the context.
- **Invariant**: an agent service must never directly invoke another agent service. The "connection" is always a `postMessage` on Slack that triggers a new round through an event. This ensures every hop is auditable, traceable, and budget-checkable.

## Session Tracking

Sessions link Slack messages to their processing context and form the backbone of delegation chain tracking.

### Session lifecycle

1. An event arrives and the router creates a `userAuthContext` (or inherits one from the parent session).
2. The agent service executes and prepares a reply.
3. When the reply is posted via `SlackWrapper.postMessage`, the returned Slack message `ts` becomes the session key.
4. A `SessionRecord` is stored: `{ sessionId, slackMessageId, userAuthContextId, agentId, parentSessionId }`.
5. If that reply triggers a new event (e.g., another agent picks it up), the new session links back via `parentSessionId`.

### Session ID format

`{agent_name}_{user_id}_{unique_incremental_id}`

Used as a stable identifier during processing, before a `slackMessageId` is available.

### Delegation chain reconstruction

The full delegation chain is reconstructable by walking the `parentSessionId` links from any session record back to the root session (which has no parent). This provides:

- Full audit trail of which agents were involved.
- The original user who initiated the chain.
- Round count validation (by counting the chain depth).

## Task Execution Model

### Task lifecycle (planned)

- `queued -> running -> {succeeded | failed | cancelled}`
- Retry states with exponential backoff and maximum attempts.
- Each task stores:
  - workspace id
  - initiator (Slack user ID from `userAuthContext`)
  - capabilities snapshot (tool allowlist + budget ceilings at enqueue time)
  - idempotency key (to dedupe duplicate events)
  - audit metadata (timestamps, attempt count, last error)

### Execution responsibility

- Event handlers should avoid long awaits; they should enqueue tasks.
- `runTasks` owns long-running work (LLM calls, tool execution, external I/O).

## Concurrency and Await Safety

Internet Computer execution can interleave at `await` points.
Design rules (planned and recommended for any new code):

- Update task status to `running` before the first `await`.
- Wrap with try {} catch to log trap messages and keep history of trap logs for future audit.
- Make tasks step based and logged on every await that succeeds, ensuring that if a trap happens, it skips the successful steps and restarts on the failed step.

## Timers and Scheduling

### Current

- Key-derivation cache clearing timer (30 days).
- Metric datapoints retention cleanup timer (30 days).
- Processed events cleanup timer (7 days): fails stale unprocessed events, purges old processed/failed events.
- Keep timer state minimal and upgrade-safe (store "next run time" and reschedule in `postupgrade`).

Relevant code: [src/open-org-backend/main.mo](src/open-org-backend/main.mo)

### Planned

- **Weekly reconciliation timer** (Sundays): full Slack user and channel membership sync. Also verifies workspace and org admin channel IDs.
- **Auth token purge timer**: periodic cleanup of expired tokens.
- **Task runner timer**: kick `runTasks` periodically.
- **Recurring task timer**: goal-monitoring, reporting, and dashboard alerts.

## Tooling and Integrations

### Current

- **Function tool registry**: static, resource-gated. Tools are available based on provided resources (e.g., `web_search` needs `groqApiKey`, `save_value_stream` needs workspace + write flag). See [src/open-org-backend/tools/function-tool-registry.mo](src/open-org-backend/tools/function-tool-registry.mo).
- **MCP tool registry**: dynamic, runtime-configurable. Registration/unregistration supported; execution not yet implemented.
- **Tool executor**: routes tool calls from LLM responses to function tools or MCP tools.
- **SlackWrapper**: outbound Slack API calls (`postMessage`). See [src/open-org-backend/wrappers](src/open-org-backend/wrappers).

### Planned

- **SlackWrapper expansion**: add private internal functions matching Slack API method names (`users_list()`, `conversations_list()`, `conversations_members()`), with parameters aligned to Slack's API. Public higher-level functions (e.g., `getWorkspaceMembers()`, `listChannels()`) wrap these for use by internal services. Adapter pattern: the wrapper is the single boundary for all Slack API I/O.
- **Tool scoping**: tools have access level requirements (`org`, `team`, `admin`). Enforcement happens at the Agent Router level by comparing the tool's required level against the `userAuthContext`.
- **Category tools**: each agent category service defines a `category_tools` array of tool enum variants. Agents within the category configure `toolsAllowed` (a subset) and `toolsState` (per-tool runtime data).
- **Interactive Messages**: support for `block_actions` and `view_submission` payloads in the Slack adapter. First use case: workspace onboarding (channel selection, manual ID entry).
- Agents empowered with:
  - LLM internal tools (function calling).
  - Remote MCPs.
  - Custom functions (run inside the canister).
  - Custom functions (run externally, lambdas, RPCs).
  - Deployed canisters with custom code.

## LLM Providers and Wrappers

- Providers are represented by a tagged enum. See [src/open-org-backend/types.mo](src/open-org-backend/types.mo).
- Wrappers isolate HTTP request/response formatting, headers, retries, and error mapping.

Wrappers live in: [src/open-org-backend/wrappers](src/open-org-backend/wrappers)

## Secrets, API Keys, and Encryption

### Current

- Secrets are encrypted at rest per workspace using keys derived from ICP Threshold Schnorr signatures.
- Secret types: `#groqApiKey`, `#openaiApiKey`, `#slackSigningSecret`, `#slackBotToken`.
- Per-workspace encryption key cache (transient, cleared periodically).

Deep dive entrypoints:

- [src/open-org-backend/models/secret-model.mo](src/open-org-backend/models/secret-model.mo)
- [src/open-org-backend/services/key-derivation-service.mo](src/open-org-backend/services/key-derivation-service.mo)

### Planned

- Agent `toolsState.knowHow` may reference secret keys by name, documenting which secrets a tool needs and where to find them. The actual decryption still goes through the standard `SecretModel` path, scoped to the workspace.

## Observability and Impact Tracking

### Minimal baseline (recommended)

- Append-only audit log for admin actions (bounded).
- Session tracking provides full delegation chain visibility.
- Counters for:
  - tasks queued/running/succeeded/failed
  - provider calls (by provider/model)
  - error categories
  - agent round counts and force-termination rates
- Optional attribution links: task -> goal metric(s) it was intended to move.

## Cost Controls and Budgeting

### Policy-first approach (planned)

- Budgets should be enforced by policy checks before enqueuing tasks.
- Track spend/usage independently from policy so forks can swap billing models.
- Use conservative defaults: allowlists, per-workspace limits, and approvals for risky tools.
- Agent round tracking provides a natural cost boundary: the progressive classifier after round 10 ensures escalating scrutiny on long-running chains.

## Error Handling and Retries

- Retries belong in the task runner, not in intake handlers.
- Distinguish:
  - deterministic validation errors (do not retry)
  - transient provider/network errors (retry with backoff)
  - quota/budget errors (do not retry; require policy change)

## Data Retention and Privacy

- Conversations and events should be bounded (size and/or time) to avoid unbounded state growth.
- Per-workspace retention policies.
- Avoid storing raw external event payloads longer than needed; store normalized summaries.
- Auth tokens are short-lived (expire in 1h). Expired ones are deleted every Sunday on a clean up Timer.
- Session records should have a retention policy (bounded by time or count).
- Read-only query responses never expose personal or sensitive data — only aggregated stats and resource summaries.

## Upgrade and Persistence Strategy

- Ensure timers are re-established after upgrades.
- Be aware of IC migration requirement, when changing any data type, you must define an upgrade function.
- The migration from Principal-based auth to Slack-derived identity is a clean break (no production state to migrate).

## Testing Strategy

- Motoko unit tests for pure services.
- TypeScript tests (PocketIC) for canister API behavior and any Unit Test that needs Cassettes (Mocked HTTP Outcalls).
- Slack event flows should be tested with cassettes simulating Slack API responses (`users.list`, `conversations.members`, etc.).

See:

- [tests/unit-tests](tests/unit-tests)
- [tests/integration-tests](tests/integration-tests)
- [tests/cassettes](tests/cassettes)

## Local Development and Reproducibility

- Use Bun for scripts and tests.
- Keep secrets out of git; tests load keys from `.env.test`.

## Deep Dives

- Controller layer: [src/open-org-backend/main.mo](src/open-org-backend/main.mo)
- Services: [src/open-org-backend/services](src/open-org-backend/services)
- Wrappers and outcalls: [src/open-org-backend/wrappers](src/open-org-backend/wrappers)
- Event system: [src/open-org-backend/events](src/open-org-backend/events)
- Tools: [src/open-org-backend/tools](src/open-org-backend/tools)
- Models: [src/open-org-backend/models](src/open-org-backend/models)
- Cassette system: [tests/lib](tests/lib) and [tests/cassettes](tests/cassettes)

## Glossary

- **Workspace**: a unit of policy, access, budget, and goals, mapped to a pair of Slack channels (admin + member).
- **UserAuthContext**: resolved identity and permissions of the human user, derived from Slack, carried through agent delegations.
- **Session**: a tracking record linking a Slack message ID to the agent and user auth context that produced it.
- **Agent**: a named, configurable LLM entity with specific tools, skills, and a know-how base.
- **Agent Category**: a class of agent behavior (admin, research, communication, coding) with a shared tool set definition.
- **Agent Router**: the dispatcher that selects the appropriate agent service and enforces round limits.
- **Policy**: declarative constraints over tasks, tools, budgets, and permissions.
- **Task**: queued work item executed asynchronously.
- **Event**: normalized inbound signal from Slack (or a future integration).
- **SlackWrapper**: the adapter boundary for all Slack API I/O (both inbound parsing and outbound calls).
- **`::` syntax**: the prefix notation (`::agentname`) for referencing agents in Slack messages.

## Open Questions

- Which metrics define "impact" for the first real use case (and how are they measured)?
- What is the initial tool allowlist and approval workflow?
- How should the progressive cost classifier (after round 10) be calibrated? What thresholds define "worth the cost"?
- What is the retention policy for session records?
- Should the bot support Slack threads as separate conversation contexts, or always scope conversations to the top-level message?
