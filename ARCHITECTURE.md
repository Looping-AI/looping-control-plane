# Architecture

This is a living document. It focuses on design intent, invariants, rationale, and links to code for implementation details.

## Purpose

This repo is meant to be forked and adapted to personal or organizational use.
The long-term goal is an autonomous multi-agent system that behaves more like a team than a single assistant: a set of specialized agents can ingest requests and events, plan work, run tasks via tools/LLMs, measure impact against goals, and manage cost trade-offs.

This is a **strongly opinionated framework** focused on **Slack as the primary user experience layer**. By inheriting Slack's user management, channel-based permissions, and event-driven security model, the system gains easier onboarding, a more robust security posture, and a simpler authorization model compared to implementing custom user management.

## Reading Guide

Read until "Core Flows" for a high-level view of what exists today and where the design is headed. After that, the document becomes more technical and is most useful when you're changing or debugging a specific subsystem (timers, encryption, wrappers, or tests). "Deep Dives" links you directly to the implementation files for quick reference.

## Key Goals

- Keep the framework composable and extensible, so teams can adapt it either by forking it or by implementing their own Loops on top of the core.
- Make authorization and policy explicit at the controller and data classes layers.
- Process all webhook events through the event store and queued handler pipeline, rather than handling them inline at ingress.
- Make agent behavior observable and transparent in Slack threads, so each request can clearly show what actions were taken, what results were returned, what consequences or state changes followed, and how cost was incurred.
- Track performance and cost with enough structure to support ongoing improvements and optimization.
- Be safe-by-default: secrets encrypted at rest, HMAC verification of webhook events, conservative tool access, audit logs, non-training LLM subscription providers, etc.
- Slack-first: all write operations originate from Slack or internal Timers, with a clear "User" that is signing the request; all read operations are gated by short-lived, resource-based auth tokens.

## Non-Goals (for now)

- Cycles cost and top-ups.
- Frontend Canister to easily do the read operations, with short-lived tokens.
- Guaranteed perfect autonomy; humans remain in the loop via goals, preferences in operating procedures, policies, and approvals.

## System Overview

### Current implementation (today)

- Single Motoko backend canister receiving Slack events via `http_request` / `http_request_update`.
- Slack event adapter with HMAC-SHA256 signature verification and event normalization.
- Event store with lifecycle management (unprocessed → processed/failed) and per-event timer dispatch.
- Event router dispatching to handlers (message handler fully implemented, others stubbed).
- Workspace admin and work-planning orchestrators calling LLM services with function tools.
- Tool infrastructure: static function tool registry (resource-gated) and dynamic MCP tool registry.
- Metrics, value streams, and objectives models (org-level metrics, workspace-scoped value streams/objectives).
- API keys and secrets encrypted at rest using workspace-scoped derived keys (ICP Threshold Schnorr).
- LLM provider integration via HTTP outcalls (OpenRouter).
- Credential cascade implemented in secrets model: agent override (`secretOverrides`) -> workspace -> org fallback, with access audit logging.
- Identity and authorization derived from Slack, with workspace administration anchored on admin channels.
- Agent registry with `::` routing and category-based dispatch via Agent Router.
- Session tracking linking Slack message IDs to user auth context and agent execution context.

Primary code entrypoint: [src/control-plane-core/main.mo](src/control-plane-core/main.mo)

### Target direction (what this architecture file plans for)

- **Multi-source webhook ingress**: The canister accepts writes from Slack (primary) and GitHub webhooks (agent session lifecycle and result callbacks). Each source has its own HMAC-SHA256 signature verification. Slack remains the primary user interaction layer.
- **Agent execution types**: Two fundamentally different agent modes — `#api` agents run inside the canister calling LLM APIs directly (OpenRouter), while `#runtime(#githubCodingAgent)` agents run remotely through GitHub Coding Agents in agent-specific repositories. The canister acts as control plane for both.
- **GitHub Coding Agent integration**: Each runtime agent maps to its own GitHub repository. The canister triggers agent sessions via GitHub Actions `workflow_dispatch`, tracks session state, and receives signed webhook callbacks with structured results.
- **GitHub agent delegation**: For `#runtime` agents, the canister dispatches a GitHub Actions workflow run in the agent's repository, receives session results via GitHub webhook, then composes and posts the final Slack reply.
- **Admin-channel-only workspace model**: each workspace is anchored by an admin channel. The member-channel concept and workspace member role are removed from the target model.
- **Agent channel allowlist**: each agent has an explicit list of Slack channels where it is allowed to run. Agents are still configured from the workspace admin channel, but execution is gated by this per-agent allowlist.
- **Out-of-allowlist behavior**: when an agent is referenced outside its allowed channels, execution is blocked and the bot posts an automatic warning describing allowed channels and instructing users to contact a workspace admin to update the allowlist.
- **Process Engine (Loop Engine)**: the core execution model for this control plane. All agent invocations, multi-turn LLM conversations, and delegation chains are modelled as processes. `LoopEngine.step(process, event) → [Effect]` is a pure function; the Effect Applicator executes the resulting effects.
- **Effect-driven execution**: the only mechanism for side effects is the effect list returned by a process step — `StateWrite`, `SlackPost`, `EventEmit`, `ProcessSuspend`. Process logic never writes state or does POST calls to external APIs directly.
- **Channel History**: timeline of Slack messages per channel, optimized for append operations. The source material for building agent context; separate from agent memory. Slack message-edit events can mutate past entries, so the structure needs to support retroactive updates without assuming strict immutability.
- **Agent Session**: one per agent, spanning all channels the agent is invited to. The Agent Session is the persistent memory context for that agent — it accumulates channel history entries from every channel the agent participates in, tagged with channel ID, user, and timestamp. On each `Process.step`, the session is dynamically constructed from this multi-channel history, compacted to fit the context window, and injected into the LLM prompt. Compaction and pruning happen within the Agent Session, not per-channel.
- **Store**: a file-like key-value store (`filename: Text`, `content: Text`) used to persist structured agent knowledge — `USER.md`, `AGENTS.md`, `SOUL.md`, task logs, configuration files, etc. In the Agent Runner, Store entries map directly to git-tracked files.
- **Skills system**: versioned, composable agent capabilities in an `npx`-style registry. Skills bundle prompt templates, tool configurations, MCP setup scripts, and knowledge documents. Refined regularly; passed to the Agent Runner at session start for installation.
- **Hierarchical credential management**: org (shared) → workspace (shared) → agent (individual), with multi-layered protection: audit logging, message/prompt scanning for unintended secret exposure, and environment-variable isolation in the runner.
- **Agent Runner scope boundary**: runtime agent execution (Copilot session, tool use, file operations) lives in a dedicated GitHub repository. The control plane dispatches sessions, tracks state, and receives results — it does not contain the runner implementation.
- Read-only external access via resource-based, short-lived (1h) auth tokens generated within the canister (future).
- Interactive Messages (block actions, view submissions) for configuration and onboarding flows (future).

## Architecture Principles

- Separation of concerns (control plane layers):
  - **Ingress layer**: verify HMAC signatures, normalize raw webhook payloads into typed events, and enqueue for dispatch. No business logic; pure parsing and validation.
  - **Event Dispatch**: claim events from the queue and route by `event.type` to the appropriate process handler.
  - **Process Engine (Loop Engine)**: pure functional step model — `Process.step(process, event) → [Effect]`. A process is a stateful, multi-step computation driven by events; each step is a pure function returning a list of effects. Process logic is deterministic, composable, and testable in isolation.
  - **Effect Applicator**: executes the effects returned by the Process Engine. Effect types: `StateWrite` (persist state), `SlackPost` (post a Slack message), `EventEmit` (schedule an immediate or delayed event), `ProcessSuspend` (park the process until a future event arrives). All side effects are concentrated here.
  - **Controller layer**: authentication/authorization/validation and policy checks at the canister update boundary. Guard rails live here, not inside process logic.
  - **Wrappers**: encapsulation of external API calls (Slack, GitHub, LLM providers). Called by the Effect Applicator; keeps effect handling free of raw HTTP details.
- Verified-source security: all write operations must originate from a verified source — Slack events (HMAC-SHA256 with signing secret) or GitHub webhooks (HMAC-SHA256 with webhook secret). The canister never trusts a write that doesn't come through a verified webhook signature. Slack remains the primary user interaction layer.
- "Enqueue, step, emit": request handlers enqueue events; the Process Engine steps over them and emits effects. No long-running work happens inline at ingress.
- LLMs will use Policies, Tools and Knowledge as a flexible way to execute tasks, and will only code them as they become more frequent and easier to standardize.
- Have explicit approval flows, guard-rails, for context control, without micro-managing (tool access, spending limits, any other custom approval defined in a Policy).
- Mixture of agents is desired as a strategy (Lower input/context window, easier A/B testing for cost/quality optimizing, lower risk on model upgrading).
- Auditable: the system should be auditable (events, session tracking, and conversation history).
- Avoid LLM Obedience: be resilient to prompt injection and spoofed events (Through Slack signature verification, data classes, and policies).
- Agent isolation: a process step must never invoke another agent process directly. Inter-agent communication flows through the `SlackPost` effect (posting to Slack), which re-enters the system as a new Slack event — ensuring every hop is auditable, budget-checkable, and recorded in each agent's session.

## Motoko Conventions

- **Model function parameter order**: new model functions must place the state/collection parameter **first**. This aligns with `mo:core` idioms (e.g. `Map.get(map, compare, key)`) and makes partial application natural. Example: `forkAgent(state, originalId, ...)`. Existing functions that pre-date this convention (`register`, `updateById`, etc.) have state last and will be migrated in a future cleanup pass.

## Core Concepts

### Workspace

A unit of policy, goals, knowledge, and shared state. Each workspace maps to:

- `id`: unique numeric identifier (0 = the org workspace, always exists).
- `name`: human-readable name.
- `adminChannelId`: Slack channel ID whose members are workspace admins.

Target model note: workspaces no longer define a member channel. Agent execution access is controlled by per-agent Slack channel allowlists.

### User Auth Context

The resolved identity and permissions of the user who initiated a request. Built from the Slack user cache at event-processing time and passed into all agent process handlers. Contains:

- `slackUserId`: the Slack user ID.
- `isPrimaryOwner`: whether this user is the Slack Primary Owner.
- `isOrgAdmin`: whether this user is a member of `#looping-ai-org-admins`.
- `workspaceScopes`: per-workspace admin scope — `Map<workspaceId, #admin>`. In the simplified target model there is no workspace `#member` role.
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

### Agent Execution Type

Agents have one of two execution types:

- **`#api`**: Runs inside the canister. The canister calls LLM APIs directly (OpenRouter), executes tool loops in-canister, and posts replies to Slack. Uses canister-level secrets (e.g., OpenRouter API key). Examples: workspace-admin, work-planning agents.
- **`#runtime(#githubCodingAgent)`**: Runs remotely through GitHub Coding Agents in an agent-specific repository. The canister dispatches a workflow run (`workflow_dispatch`) with the session payload, receives a structured result via signed GitHub webhook, then composes and posts the final Slack reply.

The `AgentRouter` branches on execution type before dispatching. The `#runtime` variant is extensible for future runtime types beyond GitHub Coding Agents.

### Agent Category

A class of agent behavior (e.g., admin, research, communication, coding). Each category defines:

- `category_tools`: the set of tool enum variants available to agents in this category.
- LLM model selection strategy.
- Template Skills and source/knowledge configuration.

### Policies

Text-based rules governing what is allowed or not. Applied at the workspace level to constrain tasks, tools, budgets, and permissions. From these text based documents, logic rules are captured and converted into Dynamic Logic, formal logic, rules. Then they should be upheld when accessing tools. Maybe consider using an adaptation of Cedar Policy framework https://github.com/cedar-policy/cedar-authorization.

### Events

Normalized inbound signals derived from verified external sources (Slack, GitHub).
All system state mutations are driven exclusively by Events (or internally scheduled Tasks).
Each event source has its own HMAC-SHA256 signature verification — Slack uses a signing secret and GitHub uses a webhook secret.
Slack remains the primary user interaction layer; GitHub webhooks handle runtime session lifecycle and agent response delivery.

### Tasks and Processes

The only two sources of system activity are (a) a verified inbound webhook (Slack or GitHub) and (b) an event emitted by the system itself via the `EventEmit` effect — either immediately or after a delay (timer/heartbeat). There is no other entry point.

Work is modelled as **Processes**: stateful, multi-step computations driven by events and returning effects. "Tasks" in legacy code are a simplified form of this model.

### Process

A stateful, multi-step computation driven by events. A process encapsulates its current step state, accumulated context, and a resume trigger for suspended continuations. Each step is computed by `Process.step(process, event) → [Effect]` — a pure function that never side-effects directly. Processes can be suspended (`ProcessSuspend`) waiting for a future event (e.g., a GitHub webhook callback, a timer tick) and resumed when it arrives.

### Effect

A declarative, type-safe description of a side effect, returned by a process step and executed by the Effect Applicator. Effect types:

- `StateWrite`: persist a state mutation.
- `SlackPost`: post a message to a Slack channel or thread; returns a Slack `ts` used downstream.
- `EventEmit`: schedule an event — immediate (next dispatch loop tick) or delayed (timer-based cron emulation).
- `ProcessSuspend`: park the process in the process store until a specified future event arrives.

Separating pure process logic from effect execution makes the Process Engine testable without any external dependencies.

### Store

A file-like key-value store where each entry has `filename: Text` and `content: Text`, with `#read` / `#write` access modes. Used to persist structured and unstructured agent knowledge: `USER.md`, `AGENTS.md`, `SOUL.md`/`IDENTITY.md`, `tasks.jsonl`, `daily_log.jsonl`, configuration files, etc. Within the control plane a Store entry is a canister-persisted map entry. In the Agent Runner, Store entries map directly to git-tracked files in the agent repository, with auto-backup on a daily or activity-triggered commit.

### Channel History

A timeline of Slack messages for a single channel — who said what and when. Channel History is the raw source material; it does not belong to any agent. All agents that are invited to a channel draw from the same Channel History. It is stored in the `conversationStore` and retained with a time-based expiry.

Writes are the common case (new messages), but Slack can send `message_changed` events for edited messages at any time. The structure is optimised for writes and the common read path, with retroactive edits applied when the corresponding event arrives. No strict immutability is assumed.

### Agent Session

One per agent, persistent across all channels the agent is invited to. The Agent Session accumulates entries from every Channel History the agent has access to, each tagged with channel ID, Slack user ID, and timestamp. This is the agent's memory.

On each `Process.step`, the Agent Session is dynamically constructed into a structured, compacted JSON context — clearly describing who said what, in which channel, and when — and prepended to the LLM prompt. The active user message being answered in the current turn is explicitly identified in this context.

Compaction and pruning (summarising older entries to free context space) happen within the Agent Session. If the session grows beyond the context limit a compaction pass runs, producing a summarised representation of older history.

Isolation is agent-scoped: if an agent is not invited to a channel, it has no access to that channel's history and that channel's messages do not appear in its session. Users should be aware that any message in a channel an agent is invited to may influence that agent's context — the isolation boundary is the agent, not the thread or the message.

### Skills

Versioned, composable agent capabilities distributed in an `npx`-style registry. The canister maintains a version-controlled skills index, refined on a regular schedule (e.g., weekly). A skill bundles LLM prompt templates, tool configurations, MCP setup scripts, and knowledge documents. Agents reference skills by name and version; when an Agent Session is dispatched to the Agent Runner, the required skills are passed for installation at session start (via `npm install` or MCP setup).

## External Interfaces

### Write Surface — Verified Webhooks

All write operations enter the canister through verified webhook endpoints:

- **Slack Events API** (`http_request_update` at `/webhook/slack`): messages, app mentions, channel membership changes, interactive message callbacks. HMAC-SHA256 with Slack signing secret + timestamp replay protection.
- **GitHub Webhooks** (`http_request_update` at `/github/webhook`): workflow lifecycle and runtime agent session result callbacks from GitHub Actions. HMAC-SHA256 with `X-Hub-Signature-256` header using a stored GitHub webhook secret.
- **Slack API** (outbound HTTP outcalls): the canister calls Slack to post messages, read user lists, and read channel memberships.

No canister `update` methods are exposed for external clients. Each webhook source has its own signature verification as the authentication layer.

### Read Surface — Token-Gated Queries

All external read access requires a **resource-based, read-only, short-lived (1h) auth token**:

- Tokens are generated inside the canister, triggered by a Slack command from the user.
- Token generation is logged for any future access audit.
- Each token maps to `{ slackUserId, isOrgAdmin, workspaceAdminScopes: [workspaceId], resourceScope, expiry }`.
- Query methods validate the token, check expiry, and return scoped data.
- Token storage is persistent, short-lived (1h) and cleaned up on a weekly Timer.
- No sensitive or personal data is exposed — only aggregated stats and summaries scoped to the token's access level.

This design aligns with security best practices: short-lived tokens, server-side generation, logged access, and minimal data exposure.

### Interactions

- **Slack** (primary, implemented): Events API, Web API (`postMessage`, `users.list`, `conversations.list`, `conversations.members`).
- **GitHub** (planned): GitHub Actions APIs for `workflow_dispatch` session execution, run status APIs, and webhook delivery for agent session lifecycle and result callbacks.
- **OpenRouter** (implemented): OpenAI-compatible chat completions API used by canister `#api` agents. HTTP outcalls for LLM inference.
- **Slack Interactive Messages** (future): `block_actions` and `view_submission` payloads for configuration and onboarding UX.

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

### Agent talk flow — `#api` execution (current)

1. Message handler receives a normalized message event.
2. Scopes workspace data, derives encryption key, decrypts secrets.
3. Calls orchestrator → LLM service (OpenRouter).
4. Multi-turn LLM conversation loop (up to 10 iterations) with function tool calling.
5. Posts reply to Slack via `SlackWrapper.postMessage` (threaded if original was threaded).

### Agent talk flow — `#runtime(#githubCodingAgent)` execution (planned)

1. Message handler receives a normalized message event referencing a `#runtime(#githubCodingAgent)` agent.
2. Resolves the agent's GitHub repository and workflow from agent runtime configuration.
3. Resolves required secrets via credential cascade and prepares a signed session payload.
4. Canister triggers `workflow_dispatch` in the agent repository via GitHub API.
5. GitHub Actions runs the session in the agent repo and emits lifecycle events.
6. GitHub posts a signed webhook callback with structured session result payload to `/github/webhook`.
7. Canister correlates `requestId/sessionId`, injects response into the conversation context.
8. Canister composes the final Slack reply and posts it.

### Agent repository binding flow (planned)

1. Workspace admin configures a runtime agent with repository metadata (owner/repo, workflow file/ref, branch/ref constraints).
2. Canister validates repository reachability and workflow availability through GitHub API.
3. Canister stores runtime configuration in the agent record (`#runtime(#githubCodingAgent)` config).
4. Future sessions for that agent dispatch only to that configured repository/workflow.

### Agent-to-agent delegation (planned)

1. User sends `@looping ::accounting deliver me a report on last financials`.
2. Event router resolves `::accounting` from the agent registry, builds `userAuthContext` from `SlackUserModel` (the Slack user cache).
3. `::accounting` agent process handles the request, determines it needs data from `::tech`.
4. `::accounting` posts a Slack message referencing `::tech` (architectural invariant: never invoke another agent process directly).
5. That message triggers a new Slack event → event router picks it up.
6. Router reconstructs the `userAuthContext` from the parent session (including incremented `roundCount`), creates a new session with `parentSessionId` linking to the previous one.
7. `::tech` processes with the original user's access scopes but its own tools/skills.
8. `::tech` replies → new event → router returns control to `::accounting`.
9. `::accounting` compiles the report and replies to the original user.
10. If sensitive data was accessed at a higher level than the channel allows, the bot sends a generic acknowledgement in the original channel and delivers the detailed reply in the user's DM or the appropriate scoped channel.

### Token generation flow (planned)

1. User sends a DM to the bot requesting access (e.g., a command or prompted text).
2. Bot resolves user's `userAuthContext` from the Slack user cache.
3. Bot generates a resource-based, read-only token inside the canister using the resolved `SlackUserEntry`. Stores `{ slackUserId, isOrgAdmin, workspaceAdminScopes: [workspaceId], resourceScope, expiry: now + 1h }`.
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
2. Bot presents an interactive message: workspace name and selection of the admin channel (public or private where bot has access), or manual channel ID entry.
3. If the selected channel is not accessible, the bot guides the user to run `/invite @looping` in that channel first.
4. Bot creates the workspace record and enables agent configuration from that admin channel (including per-agent channel allowlists).

## State Model

### Current persistent state

See [src/control-plane-core/main.mo](src/control-plane-core/main.mo).

- `agentRegistry`: global agent registry with dual index by ID and name (Phase 1.1, implemented).
- `conversationStore`: channel-keyed, timeline-structured message history with 1-month ts-based retention (Phase 1.4, implemented). Replaces old `conversations` / `adminConversations` workspace-keyed maps. Round tracking is embedded here — each `ConversationMessage` carries a `userAuthContext` field (`roundCount`, `forceTerminated`) so no separate round-context store is needed. See [src/control-plane-core/middleware/slack-auth-middleware.mo](src/control-plane-core/middleware/slack-auth-middleware.mo) for the `UserAuthContext` type.
- `slackUsers`: Slack user cache (`SlackUserEntry` records indexed by Slack user ID); populated by event-driven membership events and weekly reconciliation.
- `workspaces`: workspace channel anchors (`WorkspaceRecord` indexed by workspace ID, each with `adminChannelId` / `memberChannelId`). Workspace 0 ("Default") is the org workspace; its `adminChannelId` serves as the org-admin channel anchor.
- `secrets`: encrypted secrets per workspace.
- `mcpToolRegistry`: dynamic MCP tool registry.
- `metricsRegistry` / `metricDatapoints`: org-level metrics.
- `workspaceValueStreams` / `workspaceObjectives`: workspace-scoped value streams and objectives.
- `eventStore`: event lifecycle (unprocessed/processed/failed).
- `httpCertStore`: HTTP certification state.

### Target persistent state

- **Workspaces**: `Map<workspaceId, WorkspaceRecord>` where `WorkspaceRecord = { id, name, adminChannelId }`. Workspace 0 ("Default") is the org workspace; its `adminChannelId` serves as the org-admin channel anchor — no separate state variable needed.
- **Slack user cache**: `Map<SlackUserId, SlackUserEntry>` where `SlackUserEntry = { slackUserId, displayName, isPrimaryOwner, isOrgAdmin, workspaceAdminScopes: [workspaceId] }`. Backed by `SlackUserModel`.
- **Agent registry**: `AgentRegistryState = { nextId, agentsById: Map<Nat, AgentRecord>, agentsByName: Map<Text, Nat> }` where `AgentRecord = { id, name, category, executionType: #api | #runtime(#githubCodingAgent({ repoFullName, workflowId, ref })), workspaceId, llmModel, allowedChannelIds: [Text], secretsAllowed: [(workspaceId, SecretId)], secretOverrides: [(SecretId, Text)], toolsAllowed, toolsState: Map<Text, ToolState>, usageStats, sources }`. Dual-index for O(1) lookup by ID or name. File: [src/control-plane-core/models/agent-model.mo](src/control-plane-core/models/agent-model.mo).
- **GitHub runtime session store**: `Map<sessionId, GithubAgentSessionRecord>` where `GithubAgentSessionRecord = { sessionId, agentId, repoFullName, workflowId, runId: ?Nat64, status: #queued | #running | #succeeded | #failed | #cancelled | #unknown, requestId, startedAt, completedAt, lastWebhookAt, lastError }`. Tracks remote execution lifecycle and callback correlation. File: `src/control-plane-core/models/github-agent-session-model.mo` (new).
- **Session store**: `Map<slackMessageId, SessionRecord>` for tracking agent execution across delegation chains.
- **Auth token store**: `Map<tokenId, TokenRecord>` with `{ slackUserId, isOrgAdmin, workspaceAdminScopes: [workspaceId], resourceScope, expiry }`. Cleaned up on Sundays in a Timer.
- **Secrets**: encrypted secrets per workspace. Includes `#custom(Text)` secret types for flexible credential mapping. Per-workspace audit state: `SecretAuditState = { changeLog: List<SecretChangeEntry>, accessLog: List<SecretAccessEntry> }` tracking stores, deletes, and accesses with timestamps and sources.
- **Conversations**: channel-keyed, timeline-structured persistent store (Phase 1.4, implemented). Each channel has posts and threads indexed by Slack timestamp, with 1-month ts-based retention. See [src/control-plane-core/models/conversation-model.mo](src/control-plane-core/models/conversation-model.mo) for the `ConversationStore` structure: `Map<channelId, ChannelStore>` where `ChannelStore = { timeline: Map<ts, TimelineEntry>, replyIndex: Map<ts, rootTs> }`. `TimelineEntry` is either a `#post` (top-level message) or `#thread` (root + replies). Messages carry `userAuthContext` (null for bot replies, set for user messages) enabling LLM role mapping without additional lookups. Tool call/response artifacts are ephemeral (in-memory only, not persisted) pending Phase 1.7 session tracking.
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
  - **Agent allowlist drift**: detect channels that no longer exist or are no longer accessible and notify workspace admins to repair affected agent allowlists.

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
- The **detailed reply** is delivered in the user's DM, or the appropriate scoped admin/allowed channel.
- This split-reply behavior is determined after the LLM generates its response, by inspecting the processing steps to see if a higher scope was accessed.

## Agent System

### Agent registry

Agents are stored in a persistent registry with dual indexes (`agentsById: Map<Nat, AgentRecord>`, `agentsByName: Map<Text, Nat>`) for O(1) lookup by ID or name. Each agent record (`AgentRecord`) has:

- `id`: stable unique numeric identifier, assigned by the registry on registration.
- `name`: kebab-case identifier, must be unique and match the `::name` syntax. Stored lower-cased; lookups are case-insensitive.
- `category`: which agent category/service handles this agent (e.g., `#admin`, `#planning`, `#research`, `#communication`).
- `executionType`: determines how the agent runs — `#api` (in-canister, calls LLM directly) or `#runtime(#githubCodingAgent({ repoFullName, workflowId, ref }))` (remote, via GitHub Actions workflow dispatch). See "Agent Execution Type" in Core Concepts.
- `workspaceId`: which workspace this agent belongs to. Scopes ownership and secret access.
- `llmModel`: the LLM provider and model to use (e.g., `#openRouter(#gpt_oss_120b)`).
- `allowedChannelIds`: explicit Slack channel allowlist for agent execution. If a message references the agent outside this list, execution is blocked with an automatic warning.
- `secretsAllowed`: explicit whitelist of `(workspaceId, SecretId)` pairs this agent is permitted to access. The agent process must check this list before decrypting any secret.
- `secretOverrides`: `[(targetSecretId: SecretId, customSecretName: Text)]` — when resolving `targetSecretId`, the model first checks `#custom(customSecretName)` in the agent workspace before standard workspace/org fallback (credential cascade).
- `toolsAllowed`: subset of the category's `category_tools` that this agent is permitted to use.
- `toolsState`: per-tool runtime state (`Map<Text, ToolState>`):
  - `usageCount`: how many times this tool has been invoked by this agent.
  - `knowHow`: a Text field containing tool-specific operational knowledge — configuration state, secret key references (how to find them in Secrets), good/bad practices, documentation links, and other relevant context. This field is also used when duplicating an agent as a template: the know-how can be copied and adapted.
- `usageStats`: `{ totalPromptTokens, totalCompletionTokens, totalRequests, lastResetAt }` — accumulated from LLM responses for cost tracking.
- `sources`: knowledge sources and context configuration.

### `::` reference syntax

Users (or agents) reference agents in messages with the `::` prefix notation.

**Trigger**: `::agentname`

**Regex**: `(?<!\\)(?<!\w)::([a-z][a-z0-9-]*)`

**Ignored contexts**: inline code, code blocks, escaped `\::agent`.

**Validation**: the name must exist in the agent registry. Case-insensitive matching.

When an agent is referenced, the access scope remains that of the original user. The agent uses its own skills and tools, but scoped to the original user's `userAuthContext`.

### Agent categories

Each agent category defines the process logic that handles execution:

- `category_tools`: an array of tool enum variants available to agents in this category. This type structure is also used when configuring agent tool permissions through Slack interactive components.
- LLM model selection strategy.
- Skills and knowledge configuration.

**Phased implementation:**

- **v0.2**: Agent registry, `::` routing, admin and planning agent process handlers, Slack-only write surface.
- **v0.5**: Agent execution types (`#api` / `#runtime`), GitHub Coding Agent integration via Actions + webhooks, credential cascade, secrets hardening, Process Engine + Effect Applicator, Agent Session, Channel History, Store.
- **Future**: Full pluggable agent framework, interactive Slack messages, auth tokens, cost optimization, Skills system.

### Agent routing and round control

The **Agent Router** sits between Event Dispatch and agent process handlers.

**Pre-conditions (checked before routing begins):**

- The message must contain at least one **valid `::agentname` reference** — resolved against the agent registry at dispatch time. If no valid reference is found (e.g., the reference doesn't match any registered agent), the event is **discarded/skipped**. This prevents orphaned or malformed inter-agent messages from entering the routing loop.
- `userAuthContext.forceTerminated` must be `false`. If true, the event is **discarded/skipped** without invoking any agent process.
- The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution.

Both conditions are checked at the event router level, before the Agent Router hands off to a category service.

When a message passes pre-conditions and references an agent:

1. Resolves the agent from the registry.
2. Selects the appropriate category service.
3. Passes the `userAuthContext` and session context to the service.
4. The service executes and posts a reply to Slack.

**Round tracking** (in `userAuthContext`):

- `roundCount` increments each time the router processes a new event in the same request chain.
- **Hard upper bound**: `MAX_AGENT_ROUNDS` (10, defined in Constants). Once this limit is reached, the session is force-terminated.
- **Invariant**: an agent process must never directly invoke another agent process. The "connection" is always a `postMessage` on Slack that triggers a new round through an event. This ensures every hop is auditable, traceable, and budget-checkable.

## Session Tracking

Sessions link Slack messages to their processing context and form the backbone of delegation chain tracking.

### Session lifecycle

1. An event arrives and the router creates a `userAuthContext` (or inherits one from the parent session).
2. The agent process handler executes and prepares a reply.
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

## Process Engine (Loop Engine)

### Process model

The Process Engine implements a pure functional step model: a process step is a pure function that takes the current process state and a triggering event and returns a list of effects. No state is mutated and no I/O is performed inside the step function.

The **Effect Applicator** then executes the returned effects in order:

1. `StateWrite` — writes are committed to canister stable state.
2. `SlackPost` — the Slack wrapper sends the message; the returned `ts` is available to subsequent effects in the same batch.
3. `EventEmit` — new events are enqueued (immediate) or scheduled via the timer system (delayed/cron).
4. `ProcessSuspend` — the process is parked in the process store with a resume trigger; the Effect Applicator stores it and moves on.

### Process lifecycle

`created → running → suspended → running → … → {succeeded | failed | cancelled}`

A suspended process is re-awakened when its resume trigger event arrives and is matched by Event Dispatch. Retry logic is handled by emitting a delayed `EventEmit` that re-triggers the same step.

### Process record

Each process stores:

- `processId`: stable unique identifier.
- `workspaceId`: owning workspace.
- `initiator`: Slack user ID from `userAuthContext`.
- `capabilitiesSnapshot`: tool allowlist + budget ceilings captured at process creation time.
- `idempotencyKey`: deduplication across retried events.
- `currentStep`: the step tag or function reference.
- `suspendedAt` / `resumeTrigger`: set when `ProcessSuspend` is applied; cleared on resume.
- `auditMetadata`: timestamps, attempt count, last error.

### Execution responsibility

- Ingress handlers enqueue an event and return immediately — no awaits at ingress.
- Event Dispatch claims events one at a time and invokes `Process.step`.
- The Effect Applicator owns all I/O: Slack posts, state writes, timer scheduling, and external API calls via wrappers.
- Long-running external work (LLM calls, GitHub API calls) is mediated through effects, not inline awaits inside step functions.

## Concurrency and Await Safety

Internet Computer execution can interleave at `await` points.
Design rules (planned and recommended for any new code):

- Update process status to `running` before the first `await`.
- Wrap with try {} catch to log trap messages and keep history of trap logs for future audit.
- Make processes step-based with logged transitions at every await — if a trap occurs, completed steps are skipped and execution restarts at the failed step.

## Timers and Scheduling

### Current

- Key-derivation cache clearing timer (30 days).
- Metric datapoints retention cleanup timer (30 days).
- Processed events cleanup timer (7 days): fails stale unprocessed events, purges old processed/failed events.
- Keep timer state minimal and upgrade-safe (store "next run time" and reschedule in `postupgrade`).

Relevant code: [src/control-plane-core/main.mo](src/control-plane-core/main.mo)

### Planned

- **Weekly reconciliation timer** (Sundays): full Slack user and channel membership sync. Also verifies workspace and org admin channel IDs.
- **Auth token purge timer**: periodic cleanup of expired tokens.
- **Process Engine timer**: kick the Process Engine step loop periodically.
- **Recurring task timer**: goal-monitoring, reporting, and dashboard alerts.

## Tooling and Integrations

### Current

- **Function tool registry**: static, resource-gated. Tools are available based on provided resources (e.g., `web_search` needs API key, `save_value_stream` needs workspace + write flag). See [src/control-plane-core/tools/function-tool-registry.mo](src/control-plane-core/tools/function-tool-registry.mo).
- **MCP tool registry**: dynamic, runtime-configurable. Registration/unregistration supported; execution not yet implemented.
- **Tool executor**: routes tool calls from LLM responses to function tools or MCP tools.
- **SlackWrapper**: outbound Slack API calls (`postMessage`). See [src/control-plane-core/wrappers](src/control-plane-core/wrappers).

### Planned

- **OpenRouterWrapper**: OpenAI-compatible chat completions via OpenRouter (replacing `groq-wrapper.mo`). Same request/response types, updated URL (`openrouter.ai/api/v1`) and headers (`HTTP-Referer`, `X-Title`).
- **GitHubWrapper**: HTTP outcalls for workflow dispatch, workflow/run status queries, and repository metadata validation for runtime agents.
- **GitHubWebhookAdapter**: verifies and normalizes GitHub Actions lifecycle/result webhooks into internal events for session correlation.
- **SlackWrapper expansion**: add private internal functions matching Slack API method names (`users_list()`, `conversations_list()`, `conversations_members()`), with parameters aligned to Slack's API. Public higher-level functions (e.g., `getWorkspaceMembers()`, `listChannels()`) wrap these for use by internal services. Adapter pattern: the wrapper is the single boundary for all Slack API I/O.
- **Tool scoping**: tools have access level requirements (`org`, `team`, `admin`). Enforcement happens at the Agent Router level by comparing the tool's required level against the `userAuthContext`.
- **Category tools**: each agent category defines a `category_tools` array of tool enum variants. Agents within the category configure `toolsAllowed` (a subset) and `toolsState` (per-tool runtime data).
- **LLM tools** (for `#api` agents): a focused, powerful set — `file_read`, `file_write`, `mcp` (call an MCP tool), `browser`, `memory_search`, `skill_search`. Agents choose from this list based on `toolsAllowed`.
- **Interactive Messages** (future): support for `block_actions` and `view_submission` payloads in the Slack adapter.
- Agents empowered with:
  - LLM internal tools (function calling).
  - Remote MCPs.
  - Custom functions (run inside the canister).
  - Custom functions (run externally, lambdas, RPCs).
  - Deployed canisters with custom code.

## LLM Providers and Wrappers

- Providers are represented by a tagged enum (`LlmProvider = #openRouter`). See [src/control-plane-core/types.mo](src/control-plane-core/types.mo).
- **OpenRouter** is the canister's current LLM provider. Same OpenAI-compatible API surface, same model (`openai/gpt-oss-120b` via Groq provider on OpenRouter). URL: `openrouter.ai/api/v1`.
- Be aware that OpenRouter allows to **BYOK** (Bring Your Own Keys) for free up to 1M calls a month. Therefore **no need to set specific API providers inside our repo**.
- **Runtime-agent model execution** happens inside GitHub Coding Agent sessions. The canister receives results via webhook and does not call those runtime models directly.
- Wrappers isolate HTTP request/response formatting, headers, retries, and error mapping.

Wrappers live in: [src/control-plane-core/wrappers](src/control-plane-core/wrappers)

## Secrets, API Keys, and Encryption

### Current

- Secrets are encrypted at rest per workspace using keys derived from ICP Threshold Schnorr signatures.
- Secret types: `#openRouterApiKey`, `#anthropicApiKey`, `#anthropicSetupToken`, `#githubUserToken`, `#githubWebhookSecret`, `#slackSigningSecret`, `#slackBotToken`, `#custom(Text)`.
- Per-workspace encryption key cache (transient, cleared periodically).

Deep dive entrypoints:

- [src/control-plane-core/models/secret-model.mo](src/control-plane-core/models/secret-model.mo)
- [src/control-plane-core/services/key-derivation-service.mo](src/control-plane-core/services/key-derivation-service.mo)

### Credential Cascade

Secrets resolve through a three-level override chain:

1. **Agent-level**: Check the agent's `secretOverrides` for `(targetSecretId, customSecretName)` and then resolve `#custom(customSecretName)` in the agent's workspace.
2. **Workspace-level**: Check the agent's workspace for the standard secret ID.
3. **Org-level**: Fall back to org workspace (ws 0) for the standard secret ID.

This is implemented in [src/control-plane-core/models/secret-model.mo](src/control-plane-core/models/secret-model.mo) via `resolveSecret(state, agent, workspaceId, targetSecretId, workspaceKey, orgKey, requester) -> ?Text`.

### Audit Trails

Per-workspace `SecretAuditState` tracks:

- **Change log** (append-only): `{ timestamp, source: #adminTool | #reconciliation | #system, changeType: #stored(SecretId) | #deleted(SecretId) }`. Logged on every store/delete operation.
- **Access log** (append-only): `{ timestamp, secretId, agentId: ?Nat }`. Logged when secrets are decrypted by agent orchestrators or tool handlers.
- `purgeOldLogs(retentionNs)` cleans up old entries, wired into the weekly reconciliation timer.

Pattern follows `SlackUserModel`'s `AccessChangeLog` (source-tagged, retention-bounded).

### Planned

- Agent `toolsState.knowHow` may reference secret keys by name, documenting which secrets a tool needs and where to find them. The actual decryption still goes through the standard `SecretModel` path, scoped to the workspace.

## Observability and Impact Tracking

### Minimal baseline (recommended)

- Append-only audit log for admin actions (bounded).
- Session tracking provides full delegation chain visibility.
- Slack thread trace is the primary human-facing execution log for a session, not a separate operator-only surface.
- Each session should be able to expose its full step-by-step trace in Slack: which agent acted, which tools or sub-actions ran, what came back, what changed because of it, and where cost was incurred.
- The Slack UX may collapse or de-emphasize repeated, well-understood flows, but the full session trace should remain expandable via attachments or "show more" patterns.
- Rich Slack traceability is part of correct operation, not just debugging support: it helps humans learn the agent's way of solving problems, suggest safer or more efficient alternatives, diagnose bugs, and understand cost outliers.
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

- Retries belong in the Process Engine (via delayed `EventEmit`), not in ingress handlers.
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

- Controller layer: [src/control-plane-core/main.mo](src/control-plane-core/main.mo)
- Services: [src/control-plane-core/services](src/control-plane-core/services)
- Wrappers and outcalls: [src/control-plane-core/wrappers](src/control-plane-core/wrappers)
- Event system: [src/control-plane-core/events](src/control-plane-core/events)
- Tools: [src/control-plane-core/tools](src/control-plane-core/tools)
- Models: [src/control-plane-core/models](src/control-plane-core/models)
- Cassette system: [tests/lib](tests/lib) and [tests/cassettes](tests/cassettes)

## Glossary

- **Workspace**: a unit of policy, access, budget, and goals, anchored by an admin channel.
- **UserAuthContext**: resolved identity and permissions of the human user, derived from Slack, carried through agent delegations.
- **Session**: a tracking record linking a Slack message ID to the agent and user auth context that produced it.
- **Agent**: a named, configurable LLM entity with specific tools, skills, and a know-how base.
- **Agent Category**: a class of agent behavior (admin, research, communication, coding) with a shared tool set definition.
- **Agent Execution Type**: `#api` (runs in-canister via OpenRouter) or `#runtime(#githubCodingAgent)` (delegated to a GitHub Coding Agent session via Actions workflow dispatch).
- **Agent Router**: the dispatcher that selects the appropriate agent process handler and enforces round limits.
- **Policy**: declarative constraints over tasks, tools, budgets, and permissions.
- **Task**: queued work item executed asynchronously.
- **Event**: normalized inbound signal from Slack or GitHub.
- **SlackWrapper**: the adapter boundary for all Slack API I/O (both inbound parsing and outbound calls).
- **`::` syntax**: the prefix notation (`::agentname`) for referencing agents in Slack messages.
- **GitHub Coding Agent**: a remote runtime that executes agent sessions inside an agent-specific GitHub repository.
- **GitHub Agent Session**: one remote execution run triggered via `workflow_dispatch`, correlated back to canister session state through GitHub webhook callbacks.
- **Agent Repository**: the dedicated GitHub repository where a runtime agent's implementation and workflow live.
- **OpenRouter**: the current canister LLM provider. OpenAI-compatible API at `openrouter.ai/api/v1`.
- **Credential Cascade**: a three-level secret resolution chain — agent → workspace → org — allowing overrides at each scope.
- **Workflow Dispatch**: GitHub Actions trigger used by the canister to start a runtime agent session with structured inputs.
- **Agent Channel Allowlist**: per-agent list of Slack channels where the agent is allowed to execute.
- **Process**: a stateful, multi-step computation driven by events. Advances via `Process.step(process, event) → [Effect]`.
- **Loop Engine**: the Process Engine — the subsystem that steps processes and coordinates with the Effect Applicator.
- **Effect**: a declarative description of a side effect returned by a process step (`StateWrite`, `SlackPost`, `EventEmit`, `ProcessSuspend`).
- **Effect Applicator**: the subsystem that executes effects returned by the Process Engine. The only place where state is written or external APIs are called.
- **Store**: file-like key-value store (`filename`, `content`) used to persist structured agent knowledge in the control plane (and as git-tracked files in the Agent Runner).
- **Channel History**: per-channel Slack message timeline, optimised for writes; supports retroactive edits via `message_changed` events. The raw source material drawn on by Agent Sessions.
- **Agent Session**: per-agent persistent memory spanning all channels the agent is invited to; compacted and injected as structured context into each LLM prompt step.
- **Skills**: versioned, composable agent capability packages distributed in an `npx`-style registry; installed in the Agent Runner at session start.

## Open Questions

- Which metrics define "impact" for the first real use case (and how are they measured)?
- What is the initial tool allowlist and approval workflow?
- How should the progressive cost classifier (after round 10) be calibrated? What thresholds define "worth the cost"?
- What is the retention policy for session records?
- Should the bot support Slack threads as separate conversation contexts, or always scope conversations to the top-level message?
- What concurrency and timeout policies should govern GitHub Coding Agent sessions per workspace/agent?
- What is the reconciliation strategy when an agent repository/workflow is changed or deleted outside the control plane?
