# Architecture

This is a living document. It focuses on design intent, invariants, rationale, and links to code for implementation details.

## Purpose

This repo is meant to be forked and adapted to personal or organizational use.
The long-term goal is an autonomous multi-agent system that behaves more like a team than a single assistant: a set of specialized agents can ingest requests and events, plan work, run tasks via tools/LLMs, measure impact against goals, and manage cost trade-offs.

This is a **strongly opinionated framework** focused on **Slack as the primary user experience layer**. By inheriting Slack's user management, channel-based permissions, and event-driven security model, the system gains easier onboarding, a more robust security posture, and a simpler authorization model compared to implementing custom user management.

## Reading Guide

Read until "Core Flows" for a high-level view of what exists today and where the design is headed. After that, the document becomes more technical and is most useful when you're changing or debugging a specific subsystem (timers, encryption, wrappers, or tests). "Deep Dives" links you directly to the implementation files for quick reference.

Sections and items marked **[planned]** describe target architecture not yet implemented. Unmarked content reflects the current codebase.

## Key Goals

- Quality and delivering a trustworthy experience is the primary goal, efficiency comes second.
- Keep the framework composable and extensible, so teams can adapt it either by forking it or by implementing their own Loops on top of the core.
- Make authorization and policy explicit at the controller and data classes layers.
- Process all webhook events through the event store and queued handler pipeline, rather than handling them inline at ingress.
- Make agent behavior observable and transparent in Slack threads, so each request can clearly show what actions were taken, what results were returned, what consequences or state changes followed, and how cost was incurred.
- Track performance and cost with enough structure to support ongoing improvements and optimization.
- Be safe-by-default: secrets encrypted at rest, HMAC verification of webhook events, conservative tool access, audit logs, non-training LLM subscription providers, etc.
- Slack-first: all write operations originate from Slack or internal Timers, with a clear "User" that is signing the request; all read operations are gated by short-lived, resource-based auth tokens.

## Non-Goals (for now)

- Comprehensive cycles treasury strategy (beyond the current internal-engine keepalive top-up).
- Frontend Canister to easily do the read operations, with short-lived tokens.
- Guaranteed perfect autonomy; humans remain in the loop via goals, preferences in operating procedures, policies, and approvals.

## System Overview

### Current implementation (today)

- Two Motoko backend canisters:
  - **Control Plane Core**: Slack ingress (`http_request` / `http_request_update`), signature verification, event intake/routing, state ownership, secrets, sessions, and timers.
  - **Internal Engine**: asynchronous workflow execution canister (`execute`) with its own run store and tool handlers, calling back into Core via `workflowApi`.
- Slack event adapter with HMAC-SHA256 signature verification and normalized event mapping.
- Event store with lifecycle management (unprocessed → processed/failed) and per-event timer dispatch.
- Event router dispatching to implemented handlers (`message`, assistant thread events, `message_changed`, `message_deleted`, `member_joined_channel`, `member_left_channel`, `team_join`).
- Workspace admin (`#_system(#admin)`) category loop implemented with OpenRouter + function tools, including `dispatch_workflow` for internal-engine execution.
- `#_system(#onboarding)` and `#custom` category loops are registered/routable but currently return not-yet-implemented errors.
- Tooling split by boundary:
  - Control-plane function tools (web search, secrets management, workflow dispatch).
  - Internal-engine workflow tools (scope-based routing) with handlers for workspace, agent, Slack queue, and session policy operations.
- **Workflow envelope model** implemented (nonce/token issuance, scope grants, version stamping, and revocation). File: [src/control-plane-core/models/workflow-envelope-model.mo](src/control-plane-core/models/workflow-envelope-model.mo).
- **Workflow async effects** implemented (`milestone` / `complete`) to post Slack updates and finalize turns. File: [src/control-plane-core/services/workflow-async-effect-service.mo](src/control-plane-core/services/workflow-async-effect-service.mo).
- **Workflow Catalog system**: the internal-engine exposes `listWorkflows()` returning a hash-versioned catalog of `WorkflowDescriptor`s. Core lazily fetches the catalog on first dispatch, caches it in `workflowCatalogState`, and refreshes automatically on `#staleCatalog` errors. See [Workflow Catalog](#workflow-catalog).
- **Approval system**: workflows with a `#require("approval")` core directive pause the turn, generate a short-lived approval code, and post a Slack Block Kit message with Approve/Deny buttons. `block_actions` payloads from Slack are handled by `BlockActionsHandler`. Approval TTL is enforced by `ApprovalTimer`. See [Approval System](#approval-system).
- API keys and secrets encrypted at rest using workspace-scoped derived keys (ICP Threshold Schnorr).
- Credential cascade implemented in secrets model (agent → workspace → org), with access audit logging. See [Credential Cascade](#credential-cascade).
- Identity and authorization derived from Slack, with workspace administration anchored on admin channels.
- Agent registry with `::` routing and category-based dispatch via Agent Router.
- Session tracking linking Slack message IDs to user auth context and agent execution context. Agent session model with per-agent persistent sessions, turn logs, and trace entries (see [src/control-plane-core/models/session-model.mo](src/control-plane-core/models/session-model.mo)).
- **`AgentRunner` module** (`src/control-plane-core/agents/agent-runner.mo`): single entry point for both new-turn orchestration (`start`) and engine-completion resume (`resume`). `TurnSuspensionService` handles suspension-only outcomes; `TurnCompletionService` handles terminal outcomes with Slack I/O.

Primary code entrypoints: [src/control-plane-core/main.mo](src/control-plane-core/main.mo) and [src/internal-engine/main.mo](src/internal-engine/main.mo)

### Target direction (what this architecture file plans for)

- **Multi-source ingress**: Slack webhook ingress remains primary and implemented; GitHub webhook ingress for runtime session lifecycle is the next write-source expansion.
- **[Agent Execution Types](#agent-execution-type)**: `#canister` execution is implemented (Core + Internal Engine envelope flow); `#github` runtime execution remains planned for repo-bound remote runs.
- **[GitHub Coding Agent integration](#core-flows)**: each `#github` agent is bound to its own repository; the control plane dispatches via `workflow_dispatch`, tracks session state, and receives signed webhook callbacks with structured results.
- **Admin-channel-only workspace model**: each workspace is anchored by an admin channel. The member-channel concept and workspace member role are removed from the target model.
- **Agent channel allowlist**: each agent has an explicit list of Slack channels where it is allowed to run. Agents are still configured from the workspace admin channel, but execution is gated by this per-agent allowlist.
- **Out-of-allowlist behavior**: execution is blocked and the bot posts an automatic warning; enforcement details in [Agent routing and round control](#agent-routing-and-round-control).
- **Workflow API + async effect bridge**: the current `WorkflowApiService` + `WorkflowAsyncEffectService` pair is the implemented stepping stone toward a fuller process/effect architecture.
- **[Process Engine (Loop Engine)](#process-engine-loop-engine)**: all agent invocations, multi-turn LLM conversations, and delegation chains are modelled as processes; `LoopEngine.step(process, event) → [Effect]` is a pure function executed by the Effect Applicator.
- **[Effect-driven execution](#effect)**: the only side-effect mechanism is the effect list returned by a process step — `StateWrite`, `SlackPost`, `EventEmit`, `ProcessSuspend`. Process logic never writes state or calls external APIs directly.
- **[Channel History](#channel-history)**: per-channel Slack message timeline, append-optimised, with retroactive edit support; the source material for agent context assembly, maintained independently of agents.
- **[Agent Session](#agent-session)**: one persistent session per agent with append-only turn log and immutable trace entries; built-in compaction, age-based context fidelity (raw fields for turns < 1h, truncated for older), and timer-based cleanup.
- **[Prompt context assembly and retrieval](#prompt-context-assembly-and-embedding-retrieval)**: on each LLM call, context is assembled from Agent Session, Channel History snippets, core files, memory, and Store documents, enriched by embedding-based retrieval against multiple indexes.
- **[Store](#store)**: file-like key-value store (`path`, `name`, `extension`, `description`, `content`) for persisting structured agent knowledge; paths must be absolute (start with `/`).
- **[Skill documents](#skill-documents-store-subtype)**: skills are Store documents under `/skills/<skill-id>/` paths, not a separate first-class system.
- **[Hierarchical credential management](#credential-cascade)**: org → workspace → agent credential cascade, with audit logging, secret-exposure scanning, and environment-variable isolation in the runner.
- **Agent Runner scope boundary**: runtime agent execution (Copilot session, tool use, file operations) lives in a dedicated GitHub repository. The control plane dispatches sessions, tracks state, and receives results — it does not contain the runner implementation. No "Store" file lives in Control Plane in this type of agent, to avoid out of sync issues.
- Read-only external access via resource-based, short-lived (1h) auth tokens generated within the canister (future).
- **Interactive Messages** (`block_actions`): Slack Block Kit approval buttons implemented for the workflow approval gate. `view_submission` and broader configuration UX remain future.
- **[DM Concierge agent](#dm-concierge-agent-planned)** [planned]: a stateless, informative-only agent permanently assigned to workspace 0 that handles all DM interactions. Because all other agents require an explicit channel allowlist, DMs are currently unserved; this agent is the sole exception. Equipped with tools to trigger the weekly reconciliation runner, query agent and workspace health, and surface recovery steps for common admin issues.
- **[Agent channel aliases](#agent-channel-aliases-planned)** [planned]: agents can register short, human-friendly aliases scoped to a specific Slack channel (e.g., `::Admin`, `::Alice`). The Event Router alias resolver maps the alias to the canonical agent name before dispatch, so users never need to type the globally unique agent identifier inside a channel where the alias is unambiguous.

### System flow diagram

#### Pipeline overview

```mermaid
flowchart LR
  Ext(["Sources\nSlack · GitHub (planned)"])
  Ing["Ingress\nverify + normalize"]
  ED["Event Store\n+ Router"]
  Core["Control Plane Core\nagent orchestration + envelope issue"]
  Engine["Internal Engine\nrun store + tool execution"]
  AsyncFx["Workflow Async Effects\nSlack post + turn completion"]
  IO["Wrappers\nSlack · OpenRouter · GitHub (planned)"]
  State(["State\nsessions · history\nregistry · secrets · envelopes"])

  Ext -->|Slack webhook| Ing --> ED --> Core
  Core -->|dispatch_workflow| Engine
  Engine -->|workflowApi milestone/complete| AsyncFx --> IO -->|API calls| Ext
  Core -.->|read/write| State
  ED -.->|claim/mark| State
  AsyncFx -.->|write| State
```

#### Component detail

Dashed borders indicate planned components not yet implemented.

```mermaid
flowchart TD
    classDef planned stroke-dasharray:5 5

    S([Slack]) -->|"/webhook/slack"| SA[SlackAdapter]
  SA --> ES(["Event Store"]) --> ER[Event Router]
  ER --> MH[MessageHandler]
  MH --> AR[AgentRouter]
  AR --> AAL[AdminAgentLoop]
  AAL -->|dispatch_workflow| EDS[EngineDispatchService]
  EDS --> IE[InternalEngine.execute]
  IE --> RUN[ExecutionRunner]
  RUN -->|workflowApi milestone/complete| EAPI[Core workflowApi]
  EAPI --> AFX[WorkflowAsyncEffectService]
  AFX --> SW["SlackWrapper → Slack API"]
  AFX --> SS(["Sessions + Traces"])

  S -->|block_actions| BA[BlockActionsHandler]
  BA --> AFX

  GH([GitHub]) -->|"/github/webhook"| GHA[GitHubWebhookAdapter]
  GHA --> ES

  class GH,GHA planned
```

## Architecture Principles

- Separation of concerns (control plane layers):
  - **Controller layer**: authentication/authorization/validation at the canister update boundary.
  - **Ingress layer**: verify HMAC signatures, normalize raw webhook payloads into typed events, and enqueue for dispatch. No business logic; pure parsing and validation.
  - **Event Dispatch**: claim events from the queue and route by `event.type` to the appropriate process handler.
  - **Process Engine (Loop Engine)**: pure functional step model — `Process.step(process, event) → [Effect]`; process logic is deterministic and never side-effects directly. [→ know more](#process-engine-loop-engine)
  - **Effect Applicator**: executes effects returned by the Process Engine; the only place where state is written or external APIs are called. [→ know more](#process-engine-loop-engine)
  - **Wrappers**: encapsulate external API calls (Slack, OpenRouter, GitHub planned); called by orchestration/effect services. [→ know more](#tooling-and-integrations)
- Verified-source security: all webhook operations must originate from a verified source — Slack events (HMAC-SHA256 with signing secret) or GitHub webhooks (HMAC-SHA256 with webhook secret). The canister never trusts a hook that doesn't come through a verified signature. Slack remains the only user interaction layer.
- **Controller-only surface**: the canister exposes `http_request` and `http_request_update` as its public HTTP gateway — these are the webhook ingress points protected by per-source HMAC verification (see Verified-source security above). Beyond that gateway there are two guarded update paths: controller-only operations (critical secret setup/recovery) and `workflowApi` (transport-guarded to the spawned internal-engine principal). All other system activity is internal: timer-fired work (scheduled) or event-queue dispatch. Timer-fired operations or queue-dispatched operations may be system- or user-triggered. User-triggered operations are always attributed to both the agent executing them and the Slack user who originated the request chain.
- **Least-privilege, capability-scoped control**: grant a minimal tool set and Slack channel allowlist rather than micro-managing individual actions. Do not interrupt flows for decisions that have already been approved at the capability level — trust previously established allowlists and policies. Control at the capability boundary (which effects and tools an agent may invoke) rather than at the action level. For powerful but necessary tools (e.g., `browser`), prefer constraining _what they can reach_ (URL/domain firewall) over removing the tool entirely.
- Specialized agents is desired as a strategy (Lower input/context window, easier A/B testing for cost/quality optimizing, lower risk on model upgrading) over a single, big, monolithic agent that accumulates very distinct domains.
- Auditable: the system should be auditable (events, session, secrets and effects).
- Agent isolation: a process step must never invoke another agent process directly. Inter-agent communication flows through the `SlackPost` effect (posting to Slack), which re-enters the system as a new Slack event — ensuring every hop is auditable, budget-checkable, and recorded in each agent's session.

## Core Concepts

### Workspace

The ultimate owner of agents and it's configuration, including: policies, stored files, processes/Loops. Each workspace maps to:

- `id`: unique numeric identifier (0 = the org workspace, always exists).
- `name`: human-readable name.
- `adminChannelId`: Slack channel ID whose members are workspace admins.

Target model note: workspaces no longer define a member channel. Agent execution access is controlled by per-agent Slack channel allowlists.

### User Auth Context

The resolved identity and permissions of the user who initiated a request. Built from the Slack user cache at event-processing time and passed into all agent process handlers. Contains:

- `slackUserId`: the Slack user ID.
- `isPrimaryOwner`: whether this user is the Slack Primary Owner.
- `isOrgAdmin`: whether this user is a member of `#looping-ai-org-admins`.
- `adminWorkspaces`: set of workspace IDs where the user is an admin — `Set<Nat>`.

The `userAuthContext` is the single source of truth for authorization in all downstream operations. It is carried through agent delegations: when agent A references agent B (on a Slack Message), the `userAuthContext` of the original human user is inherited, not the agent's identity.

### Agent Session

A persistent, long-lived record per agent — not per message or per request. Exactly one session exists per `agentId` (no separate session ID); sessions are never archived or deleted independently. The session is the agent's memory container, structured as: **session record** (turn sequencing, compaction state, context-budget policy) → **turn log** (append-only execution episodes) → **trace log** (append-only per-turn operation records).

The session does not duplicate Channel History — it stores only agent-specific execution data.

**Key invariants**: isolation is agent-scoped (no access to channels the agent isn't invited to); compaction [planned] never drops events, only reduces granularity; cleanup hard-deletes turns older than 3 months while summary layers are the permanent record.

See [src/control-plane-core/models/session-model.mo](src/control-plane-core/models/session-model.mo) for the session, turn, and trace field definitions, plus session CRUD and turn cleanup behavior.

### Agent Turn

A single execution episode within an Agent Session. Turns are append-only, ordered by a monotonic `turnNumber`, and identified by a deterministic `turnId` (`"{agentId}_{turnNumber}"`). Each turn records its status, what triggered it (`sourceRef`), delegation lineage (`triggerTurnId` — walking these links reconstructs the full delegation chain), a `userAuthContext` snapshot, and aggregated cost.

Delegation lineage is carried via Slack metadata (`AgentMessageMetadata`), not a separate index.

### Turn Trace

An immutable, append-only log of execution events within a single turn. Each `TurnTraceEntry` is a self-contained record of one completed operation — no started/finished pairing. Variant tags on `detail : TraceDetail` distinguish entry types: `#llmCall`, `#toolCall`, `#slackPost`, `#contextAssembled`, `#roundLimitHit`, `#policyRejection`, `#faultRecovered`.

**Key invariants**: trace entries are never mutated or deleted by the maintenance worker. Truncation is pre-computed at trace write time into `truncatedContent`/`truncatedOutput` fields; the raw originals (`content`/`output`) are always retained. Context assembly uses raw fields for turns completed (or started) within the last hour, and truncated fields for older turns. Thinking blocks are logged in traces but excluded from context assembly. A cleanup timer hard-deletes entire turns (with their traces) older than 3 months.

### Agent

A named, configurable entity that uses an LLM with specific tools and skills. Agents are registered in a persistent agent registry and referenced via the `::` syntax in Slack messages.

### DM Concierge Agent [planned]

A special-purpose agent permanently assigned to workspace 0 (the org workspace). Because every other agent requires an explicit `allowedChannelIds` entry and DMs are not Slack channels, DMs are currently unserved. The DM Concierge is the sole exception to the channel allowlist requirement — it handles any DM directed at the bot.

Key characteristics:

- **No memory / no learning**: does not write to Agent Session or Channel History. Each interaction is fully stateless.
- **Informative only**: can answer questions about the system, agent availability, and channel routing, and guide users to the right channel or agent.
- **Admin recovery tools**: equipped with tools to trigger the weekly reconciliation runner and surface its output directly in the DM; query workspace and agent health; and walk users through common recovery flows (e.g., missing org admin channel membership, misconfigured agent allowlists).
- **Belongs to workspace 0**: cannot be moved to a workspace-specific workspace. Secret access is limited to org-level secrets only.
- **Single instance**: only one DM Concierge exists. It is bootstrapped automatically alongside workspace 0 and cannot be deleted.

### Agent Execution Type

Agents have one of two execution types:

- **`#canister`** (implemented): Core orchestrates the turn, issues a workflow envelope, and dispatches workflow execution to the internal-engine canister. The engine reports milestones and completion back through `workflowApi`, and Core posts/finalizes via async effects.
- **`#github`** [planned]: Runs remotely through GitHub Coding Agents in an agent-specific repository. The control plane dispatches a workflow run (`workflow_dispatch`) with the session payload, receives a structured result via signed GitHub webhook, then composes and posts the final Slack reply.

`workflowEngines` is validated and persisted on agent records today (`#canister | #github`). Runtime branching by engine is currently driven by tool/orchestration flow (`dispatch_workflow`) and will be expanded as `#github` execution lands.

### Workflow Catalog

The internal engine exposes a `listWorkflows()` endpoint (caller-restricted to Core) that returns a hash-versioned catalog of `WorkflowDescriptor`s. Each descriptor contains:

- `workflowName`: unique kebab-case identifier (e.g. `agents_register`).
- `description`: human-readable description forwarded to the LLM tool definition.
- `parametersJsonSchema`: raw JSON schema string used directly in the LLM tool call.
- `requiredScopes`: access scopes Core must grant before dispatching (e.g. `{ scope: "agents", access: "write" }`).
- `coreDirectives`: instructions Core must act on _before_ dispatching:
  - `#require("approval")` — suspend the turn and post a Slack Block Kit approval prompt.
  - `#preValidation(rules)` — validate arguments against external systems (e.g. `slack_channel_exists`).

Core lazily fetches the catalog on first dispatch and caches it in `workflowCatalogState`. If the engine returns `#staleCatalog`, Core refetches automatically and retries. The catalog hash is included in every `EnvelopePayload` so the engine can reject stale dispatches.

Descriptors live in [src/internal-engine/workflows/workflow-catalog.mo](src/internal-engine/workflows/workflow-catalog.mo). Core's contract definition lives in [src/control-plane-core/types/workflow-catalog.mo](src/control-plane-core/types/workflow-catalog.mo).

### Approval System

Workflows that require human confirmation carry a `#require("approval")` core directive. The approval gate flow:

1. LLM calls `dispatch_workflow` for a protected workflow (no `approvalCode` in args).
2. `WorkflowEngineHandler` generates an approval code via `ApprovalModel.request`, which stores an `ApprovalRecord` keyed by code, linked to the workflow name, original args, turn, and requesting user.
3. A Slack Block Kit message is posted to the conversation thread with Approve / Deny buttons (`action_id: approve_workflow` / `deny_workflow`). The `approvalCode` is embedded in each button's `value` field.
4. The turn transitions to `#awaitingApproval`. An `ApprovalTimer` one-shot timer is armed; if the deadline passes without a response, `resumeWithDenial("approval timed out")` fires automatically.
5. When a user clicks a button, Slack sends a `block_actions` payload to the webhook. Main.mo returns HTTP 200 immediately and schedules `BlockActionsHandler.handle` in a zero-delay timer.
6. `BlockActionsHandler` resolves the approval code, verifies the clicker is either the original requester or a workspace admin, cancels the TTL timer, marks the approval `#approved` or `#denied`, and fires `AgentRunner.resumeWithApproval` or `AgentRunner.resumeWithDenial`. The button message is replaced with an outcome line (e.g. "✅ Approved by <@userId>").
7. On approval, `resumeWithApproval` re-runs the LLM with the approval code injected as a synthetic tool result; the LLM then re-calls `dispatch_workflow` with `approvalCode` present, which passes the gate and dispatches to the engine.

Authorization: only the original requester or a workspace admin of the agent's owning workspace may click the buttons.

Approval timer state is durable across upgrades: `postupgrade` re-arms TTL timers for all turns still in `#awaitingApproval`.

See [src/control-plane-core/models/approval-model.mo](src/control-plane-core/models/approval-model.mo), [src/control-plane-core/timers/approval-timer.mo](src/control-plane-core/timers/approval-timer.mo), and [src/control-plane-core/events/handlers/block-actions-handler.mo](src/control-plane-core/events/handlers/block-actions-handler.mo).

### Agent categories

A class of agent behavior. Three categories exist: `#_system(#admin)`, `#_system(#onboarding)`, and `#custom`. Each category has its own process handler module under `src/control-plane-core/agents/categories/`.

**Implementation status:**

- **`#_system(#admin)`** (implemented): `AdminAgentLoop` — full LLM orchestration loop with function tools (web search, secrets management, workflow dispatch via catalog), context assembly, multi-round execution, and suspension handling. See [src/control-plane-core/agents/categories/system/admin-agent-loop.mo](src/control-plane-core/agents/categories/system/admin-agent-loop.mo).
- **`#_system(#onboarding)`** (stub): handler exists but returns `"category service not yet implemented"`.
- **`#custom`** (stub): handler exists but returns `"category service not yet implemented"`.

Each category defines (target model):

- `category_tools`: the set of function tools available to agents in this category. For `#admin` this is the control-plane function tool registry (web search, secrets, workflow dispatch); for `#custom` it will be a configurable subset.
- LLM model selection strategy.
- Store-backed knowledge configuration (including skill documents under `/skills/`) [planned].

### Policies (future)

Text-based rules governing what is allowed or not. Applied at the workspace level to constrain tasks, tools, budgets, and permissions. From these text based documents, logic rules are captured and converted into Dynamic Logic, formal logic, rules. Then they should be upheld when accessing tools. Maybe consider using an adaptation of Cedar Policy framework https://github.com/cedar-policy/cedar-authorization.

Policy enforcement follows the capability-scoped control principle: policies grant or restrict capabilities (tool access, allowed channels, spend limits) rather than gating individual actions. An approved capability should flow without interruption unless the policy explicitly narrows or limits it further.

### Events

Normalized inbound signals derived from verified external sources.
All system state mutations are driven exclusively by Events (or internally scheduled Tasks).
Each event source has its own HMAC-SHA256 signature verification — Slack uses a signing secret and GitHub (planned) uses a webhook secret.
Slack remains the primary user interaction layer; GitHub webhooks are planned for runtime session lifecycle and agent response delivery.

### Processes [planned]

The sources of system activity are: (a) a verified inbound webhook (Slack or GitHub), (b) an event emitted by the system itself via the `EventEmit` effect — either immediately or after a delay (timer/heartbeat), and (c) controller-only operations restricted to the canister controller principal (secret setup and recovery only). There is no other entry point.

Work is modelled as **Processes**: stateful, multi-step computations driven by events and returning effects.

### Process [planned]

A stateful, multi-step computation driven by events. A process encapsulates its current step state, accumulated context, and a resume trigger for suspended continuations. Each step is computed by `Process.step(process, event) → [Effect]` — a pure function that never side-effects directly. Processes can be suspended (`ProcessSuspend`) waiting for a future event (e.g., a GitHub webhook callback, a timer tick) and resumed when it arrives.

### Effect [planned]

A declarative, type-safe description of a side effect, returned by a process step and executed by the Effect Applicator. Effect types:

- `StateWrite`: persist a state mutation.
- `SlackPost`: post a message to a Slack channel or thread; returns a Slack `ts` used downstream.
- `EventEmit`: schedule an event — immediate (next dispatch loop tick) or delayed (timer-based cron emulation).
- `ProcessSuspend`: park the process in the process store until a specified future event arrives.

Separating pure process logic from effect execution makes the Process Engine testable without any external dependencies.

### Store [planned]

A file-like key-value store for persisting structured and unstructured agent knowledge. Each entry has `path`, `name`, `extension`, `description`, and `content`, with `#read` / `#write` access modes. Paths must be absolute (start with `/`); the system normalizes non-absolute paths automatically. The store supports hierarchical paths like a real folder tree.

`description` is metadata designed for LLM guidance: the file purpose, expected update cadence, and interaction rules. In the control plane, Store entries are canister-persisted map entries. In the Agent Runner, they map to git-tracked files with auto-backup.

### Channel History

A timeline of Slack messages for a single channel — who said what and when. Channel History is the raw source material; it does not belong to any agent. All agents that are allowlisted to a channel draw from the same Channel History. It is stored in the `channelHistoryStore` and retained with a time-based expiry.

Writes are the common case (new messages), but Slack can send `message_changed` events for edited messages at any time. The structure is optimised for writes and the common read path, with retroactive edits applied when the corresponding event arrives. No strict immutability is assumed.

### Prompt Context Assembly and Embedding Retrieval

At each LLM call, the control plane assembles a turn-specific context from multiple sources, ordered oldest → newest.

1. **Compacted session summaries**: `coldSummary` → `warmSummary` → `hotSummary` (compressed history layers from the Agent Session).
2. **Raw turns**: uncompacted turns after `lastCompactedTurnId` (recent, full-fidelity interaction traces; context assembly uses raw fields for turns < 1h old, truncated fields for older turns — see [Turn Trace](#turn-trace)).
3. **Channel History snippets**: selected messages from channels the agent is invited to, relevant to the current prompt.
4. **Core files** [planned]: policy, config, and identity documents.
5. **Store documents and embeddings** [planned]: including skill documents under `/skills/`. The current user prompt is embedded at call time and used to query embedding indexes for memory, core files, and Store documents (with optional `path` filtering).

This retrieval step is dynamic and per-call; it enriches context beyond Agent Session without mutating the session. Token budgets for each layer are deterministic, governed by `summaryTokenBudget` in the session policy (halving distribution — see [Agent Session](#agent-session)).

#### Two-Pass Focused Context Assembly [planned]

The current approach assembles context in a single pass. A known limitation of this approach is that naively including all available sources wastes tokens on irrelevant content **and** buries important material in the attention dead-zone (model performance degrades for content in the middle of a long prompt).

The planned improvement is a two-pass approach:

1. **Relevance pass**: a lightweight scan over available sources (Channel History snippets, Store documents, skill documents) to identify which sections are relevant to the current prompt — without loading full content.
2. **Assembly pass**: construct the final focused prompt using only the relevant sections, placing the most critical context at the prompt boundaries (beginning or end) per position-sensitivity best practices.

Tool-use lookups (rather than pre-loading) are the preferred mechanism for one-off document retrieval within the agent's tool set, keeping the assembled context lean.

### Skill Documents (Store Subtype) [planned]

Skills are not a separate first-class state model; they are a structured subtype of Store documents. A skill is represented by files under a skill path (for example, `/skills/create-spec/SKILL.md` plus optional companion files), using Store metadata and content.

This keeps one unified persistence model while still enabling skill-specific conventions for discovery, retrieval, and updates.

## External Interfaces

### Write Surface — Verified Webhooks

External writes enter the control plane through verified webhook endpoints:

- **Slack Events API** (`http_request_update` at `/webhook/slack`): messages, app mentions, channel membership changes, interactive message callbacks. HMAC-SHA256 with Slack signing secret + timestamp replay protection.
- **GitHub Webhooks** [planned] (`http_request_update` at `/github/webhook`): workflow lifecycle and runtime agent session result callbacks from GitHub Actions. HMAC-SHA256 with `X-Hub-Signature-256` header using a stored GitHub webhook secret.
- **Slack API** (outbound HTTP outcalls): the canister calls Slack to post messages, read user lists, and read channel memberships.

The internal-engine callback path uses a separate shared method, `workflowApi`, guarded by caller principal (must match the spawned internal engine canister). This is not an external/public client surface. Controller-restricted methods (callable only by the canister controller principal) exist for secret setup and recovery. Each webhook source has its own signature verification as the authentication layer.

### Read Surface — Token-Gated Queries [planned]

All external read access requires a **resource-based, read-only, short-lived (1h) auth token**:

- Tokens are generated inside the canister, triggered by a Slack command from the user.
- Token generation is logged for any future access audit.
- Each token maps to `{ slackUserId, isOrgAdmin, workspaceAdminScopes: [workspaceId], resourceScope, expiry }`.
- Query methods validate the token, check expiry, and return scoped data.
- Token storage is persistent, short-lived (1h) and cleaned up on a weekly Timer.
- No sensitive or personal data is exposed — only aggregated stats and summaries scoped to the token's access level.

This design aligns with security best practices: short-lived tokens, server-side generation, logged access, and minimal data exposure.

### Interactions

- **Slack** (primary, implemented): Events API, Web API (`postMessage`, `users.list`, `conversations.list`, `conversations.members`), and Interactive Payloads API (`block_actions` for approval buttons).
- **GitHub** (planned): GitHub Actions APIs for `workflow_dispatch` session execution, run status APIs, and webhook delivery for agent session lifecycle and result callbacks.
- **OpenRouter** (implemented): OpenAI-compatible APIs used by both Control Plane Core and Internal Engine loops via HTTP outcalls. Supports BYOK — no need to configure specific API provider keys in the repo; free tier covers up to 1M calls/month.
- **Slack Interactive Messages** (future): `block_actions` and `view_submission` payloads for configuration and onboarding UX.

## Core Flows

### Slack event processing (current)

1. Slack sends an event to `http_request_update`.
2. `SlackAdapter` verifies the HMAC-SHA256 signature (with timestamp replay protection).
3. `SlackAdapter` parses the raw JSON into typed structures and normalizes into an internal `Event`.
4. `EventStoreModel` enqueues the event (dedup check across all maps).
5. A `Timer.setTimer(#seconds 0)` fires `EventRouter.processSingleEvent`.
6. The router claims the event, dispatches to the appropriate handler.
7. `MessageHandler` persists the message, resolves auth/round context, creates a turn, and routes to `AgentRouter`.
8. The admin loop may dispatch a workflow envelope to Internal Engine (or return a synchronous error/response).
9. Engine milestones/completion callback through `workflowApi`; async effects post to Slack and complete the turn.
10. Event is marked as processed or failed.

### Agent talk flow — `#canister` execution (current)

1. Message handler receives a normalized message event.
2. It derives workspace/org keys, resolves secrets, and creates/updates session turn context.
3. Admin agent loop calls OpenRouter with assembled context and function tools.
4. When `dispatch_workflow` is chosen:
   a. Core checks if a workflow catalog is cached and if its hash matches. If not, it fetches `listWorkflows()` from the engine and caches the result.
   b. If the target workflow has a `#require("approval")` core directive and no valid approval code is present, Core generates an approval code, posts a Slack Block Kit message (Approve/Deny buttons) to the thread, and suspends the turn as `#awaitingApproval`. An `ApprovalTimer` is armed for TTL enforcement.
   c. Once approved (via `block_actions` → `BlockActionsHandler`) or if approval is not required, Core validates pre-validation rules, issues a workflow envelope (nonce + scope grants), and dispatches to Internal Engine.
5. Internal Engine enqueues the run, executes an LLM + tool loop (tools assembled from `scopeGrants`), and emits `milestone`/`complete` events to Core `workflowApi`.
6. Core `WorkflowAsyncEffectService` posts Slack updates and marks the turn `#pending` → terminal status with aggregated cost.

### Agent talk flow — `#github` execution (planned)

1. Message handler receives a normalized message event referencing an agent with `#github` in `workflowEngines`.
2. Resolves the agent's GitHub repository and workflow from agent runtime configuration.
3. Resolves required secrets via credential cascade and prepares a signed session payload.
4. Canister triggers `workflow_dispatch` in the agent repository via GitHub API.
5. GitHub Actions runs the session in the agent repo and emits lifecycle events.
6. GitHub posts a signed webhook callback with structured session result payload to `/github/webhook`.
7. Canister correlates `requestId/sessionId`, injects response into the conversation context.
8. Canister composes the final Slack reply and posts it.

### Agent repository binding flow (planned)

1. Workspace admin configures a `#github` agent with repository metadata (owner/repo, workflow file/ref, branch/ref constraints).
2. Canister validates repository reachability and workflow availability through GitHub API.
3. Canister stores runtime configuration in the agent record.
4. Future sessions for that agent dispatch only to that configured repository/workflow.

### Agent-to-agent delegation (planned)

1. User sends `@looping ::accounting deliver me a report on last financials`.
2. Event router resolves `::accounting` from the agent registry, builds `userAuthContext` from `SlackUserModel` (the Slack user cache).
3. `::accounting` agent process creates a new turn in its session, executes, and determines it needs data from `::tech`.
4. `::accounting` posts a Slack message referencing `::tech` (architectural invariant: never invoke another agent process directly). The message metadata includes `turnId` of the originating turn.
5. That message triggers a new Slack event → event router picks it up.
6. Router reconstructs the `userAuthContext` from the parent turn's metadata. Routing round progression and termination checks are loaded from `SessionsModel`. A new turn is created in `::tech`'s session with `triggerTurnId` pointing to `::accounting`'s turn.
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

See [src/control-plane-core/main.mo](src/control-plane-core/main.mo) and [src/internal-engine/main.mo](src/internal-engine/main.mo).

- **Control Plane Core canister**:
  - `agentRegistry`: global agent registry with dual index by ID and name.
  - `channelHistoryStore`: channel-keyed, timeline-structured message history with retention pruning.
  - `slackUsers`: Slack user cache + access change log; updated by events and weekly reconciliation.
  - `workspaces`: workspace channel anchors (`adminChannelId` only model).
  - `secrets`: encrypted secrets + per-workspace audit logs.
  - `eventStore`: unprocessed/processed/failed lifecycle maps.
  - `sessionStores`: persistent sessions, turns, traces.
  - `workflowEnvelopeState`: envelope nonce store, grants/permits, dispatch version stamps, known engine versions.
  - `workflowCatalogState`: lazily-populated workflow catalog cache (hash + descriptors fetched from engine).
  - `approvalState`: pending/resolved approval codes for the workflow approval gate; each code is linked to a workflow, turn, and requesting user.
  - `httpCertStore`: HTTP certification state.
  - `internalEnginePrincipal`: persisted engine principal used for transport-level guard on `workflowApi`.
- **Internal Engine canister**:
  - `runStore`: running/completed/failed execution lifecycle store for dispatched envelopes.

### Target persistent state

- **Workspaces**: `Map<workspaceId, WorkspaceRecord>` where `WorkspaceRecord = { id, name, adminChannelId }`. Workspace 0 ("Default") is the org workspace; its `adminChannelId` serves as the org-admin channel anchor — no separate state variable needed.
- **Slack user cache**: `Map<SlackUserId, SlackUserEntry>` where `SlackUserEntry = { slackUserId, displayName, isPrimaryOwner, isOrgAdmin, workspaceAdminScopes: [workspaceId] }`. Backed by `SlackUserModel`.
- **Agent registry**: `AgentRegistryState = { nextId, agentsById: Map<Nat, AgentRecord>, agentsByName: Map<Text, Nat> }` where `AgentRecord = { id, ownedBy, category: AgentCategory, config: AgentConfig, state: AgentState }`. `AgentCategory = { #_system: SystemAgentKind | #custom }`, `SystemAgentKind = { #admin | #onboarding }`. `AgentConfig = { name, model, workflowEngines: [WorkflowEngine], allowedChannelIds: Set<Text>, secrets: AgentSecretsConfig }`, `WorkflowEngine = { #canister | #github }`. `AgentState = { toolsState: Map<Text, ToolState> }`. Dual-index for O(1) lookup by ID or name. File: [src/control-plane-core/models/agent-model.mo](src/control-plane-core/models/agent-model.mo).
- **Agent session store**: `Map<agentId, AgentSessionRecord>` — one persistent session per agent, with compaction state (summary layers, cursor) and context-budget policy. No separate session ID; the agent ID is the key. File: [src/control-plane-core/models/session-model.mo](src/control-plane-core/models/session-model.mo).
- **Agent turn store**: `Map<agentId, List<AgentTurnRecord>>` — append-only turn log per agent. Each turn has a deterministic `turnId` (`"{agentId}_{turnNumber}"`), execution status, source ref, delegation lineage (`triggerTurnId`), user auth context snapshot, cost, and Slack reply ts list.
- **Turn trace store**: `Map<turnId, List<TurnTraceEntry>>` — immutable, append-only trace per turn. Each entry is a self-contained `TraceDetail` variant (`#llmCall`, `#toolCall`, `#slackPost`, etc.) with per-entry cost on LLM calls. Truncated fields (`truncatedContent`, `truncatedOutput`) are pre-computed at write time; raw originals always retained. Context assembly uses raw fields for turns < 1h old, truncated fields for older turns. Hard deletion after 3 months.
- **Workflow envelope store**: `Map<nonce, EnvelopeRecord>` with turn linkage, workspace scope grants, expiry/revocation, and accepted engine dispatch version. File: [src/control-plane-core/models/workflow-envelope-model.mo](src/control-plane-core/models/workflow-envelope-model.mo).
- **Internal-engine run store**: `Map<envelopeId, RunRecord>` split by `running/completed/failed`, with per-step execution detail and retention cleanup helpers. File: [src/internal-engine/models/run-store-model.mo](src/internal-engine/models/run-store-model.mo).
- **Workflow catalog cache**: `CatalogState = { cached : ?{ catalogHash : Text; descriptors : [WorkflowDescriptor] } }`. Atomic replace-only; either fully populated or absent (no stale intermediate state). File: [src/control-plane-core/models/workflow-catalog-model.mo](src/control-plane-core/models/workflow-catalog-model.mo).
- **Approval state**: `ApprovalState = { counter, approvalSalt, approvals : Map<Text, ApprovalRecord> }` where `ApprovalRecord = { code, workflowName, originalArgs, workspaceId, agentId, turnId, requestedByUserId, requestedAt, status : #pending | #approved | #denied }`. File: [src/control-plane-core/models/approval-model.mo](src/control-plane-core/models/approval-model.mo).
- **GitHub runtime session store** [planned]: `Map<sessionId, GithubAgentSessionRecord>` — tracks remote execution lifecycle and callback correlation.
- **Embedding indexes**: searchable indexes for memory records, core files, and Store documents (including skill documents under `skills/`) used during prompt-time retrieval.
- **Auth token store**: `Map<tokenId, TokenRecord>` with `{ slackUserId, isOrgAdmin, workspaceAdminScopes: [workspaceId], resourceScope, expiry }`. Cleaned up on Sundays in a Timer.
- **Secrets**: encrypted secrets per workspace. Includes `#custom(Text)` secret types for flexible credential mapping. Per-workspace audit state: `SecretAuditState = { changeLog: List<SecretChangeEntry>, accessLog: List<SecretAccessEntry> }` tracking stores, deletes, and accesses with timestamps and sources.
- **Channel History**: channel-keyed, timeline-structured persistent store (Phase 1.4, implemented). Each channel has posts and threads indexed by Slack timestamp, with 1-month ts-based retention. See [src/control-plane-core/models/channel-history-model.mo](src/control-plane-core/models/channel-history-model.mo) for the `ChannelHistoryStore` structure: `Map<channelId, ChannelStore>` where `ChannelStore = { timeline: Map<ts, TimelineEntry>, replyIndex: Map<ts, rootTs> }`. `TimelineEntry` is either a `#post` (top-level message) or `#thread` (root + replies). Messages carry `userAuthContext` (null for bot replies, set for user messages) enabling LLM role mapping without additional lookups. Tool call/response artifacts are ephemeral (in-memory only, not persisted) pending Phase 1.7 session tracking.
- **Event store**: event lifecycle with timer dispatch (existing, retained).
- **Tool registries**: control-plane function tool registry and internal-engine workflow tool registry (scope-based) are implemented; broader dynamic registries (including MCP) remain planned.

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

Resources have read/write visibility levels: `org`, `admin`.

Model examples:

- Objectives: `read: org`, `write: admin`.
- Tasks: `read: org`, `write: org`.

Tool examples:

- `web_search`: org access.
- `update_session_policy`: admin access.
- `delete_workspace`: admin access plus explicit `#deleteWorkspace` permit.

No individual access configuration is allowed. If truly needed, the org admin can create a workspace with only that individual and explicitly assign the desired resources and tools.

### Access level resolution [planned]

The access level is always determined by the **user** who wrote the original message, regardless of which channel the message was sent in. When an agent replies:

- If the reply contains data that required a higher access level than the current channel's scope, the bot sends a **generic safe acknowledgement** in the original channel.
- The **detailed reply** is delivered in the user's DM, or the appropriate scoped admin/allowed channel.
- This split-reply behavior is determined after the LLM generates its response, by inspecting the processing steps to see if a higher scope was accessed.

## Agent System

### Agent registry

Agents are stored in a persistent registry with dual indexes (`agentsById: Map<Nat, AgentRecord>`, `agentsByName: Map<Text, Nat>`) for O(1) lookup by ID or name. Each agent record (`AgentRecord`) has:

- `id`: stable unique numeric identifier, assigned by the registry on registration.
- `ownedBy`: workspace ID that owns this agent. Immutable after creation. Workspace 0 means org-wide (e.g. the org-admin agent).
- `category`: `AgentCategory = { #_system : SystemAgentKind | #custom }` where `SystemAgentKind = { #admin | #onboarding }`. Determines the available tool catalogue and prompt strategy. Immutable after creation.
- `config.name`: kebab-case identifier, must be unique and match the `::name` syntax. Stored lower-cased; lookups are case-insensitive.
- `config.model`: OpenRouter model string (e.g. `"openai/gpt-oss-120b"`).
- `config.workflowEngines`: `[WorkflowEngine]` where `WorkflowEngine = { #canister | #github }`. Non-empty list of workflow engines this agent is permitted to use. `#canister` = internal-engine workflow dispatch path; `#github` = GitHub Actions workflow dispatch (planned).
- `config.allowedChannelIds`: `Set<Text>` — Slack channel allowlist. Must be non-empty for `#custom` agents; always empty for `#_system(#admin)` (routing governed by `WorkspaceModel.adminChannelId`).
- `config.secrets.allowed`: explicit whitelist of `(workspaceId, SecretId)` pairs this agent may access.
- `config.secrets.overrides`: `[(targetSecretId, customKeyName)]` — agent-level credential override; see [Credential Cascade](#credential-cascade).
- `state.toolsState`: per-tool runtime state (`Map<Text, ToolState>`):
  - `usageCount`: how many times this tool has been invoked by this agent.
  - `knowHow`: a Text field containing tool-specific operational knowledge — configuration state, secret key references, good/bad practices, documentation links, and other relevant context.

### `::` reference syntax

Users (or agents) reference agents in messages with the `::` prefix notation.

**Trigger**: `::agentname`

**Regex**: `(?<!\\)(?<!\w)::([a-z][a-z0-9-]*)`

**Ignored contexts**: inline code, code blocks, escaped `\::agent`.

**Validation**: the name must exist in the agent registry. Case-insensitive matching.

When an agent is referenced, the access scope remains that of the original user. The agent uses its own skills and tools, but scoped to the original user's `userAuthContext`.

### Agent Channel Aliases [planned]

Agents can register short, human-friendly aliases scoped to a specific Slack channel. This lets channel members write `::Admin` or `::Alice` instead of the globally unique canonical name (`::ws-1-admin`, `::alice-2`). Aliases only need to be unique within their channel — the same alias can exist in different channels pointing to different agents.

**Model**: the registry maintains a secondary index `channelAliasIndex : Map<(channelId, alias), agentId>`. An alias is a kebab-case, lowercase text string following the same character rules as an agent name. Aliases are stored case-insensitively.

**Registration rules**:

- Two agents cannot hold the same alias in the same channel — registration is rejected if a conflict exists.
- An alias may shadow the canonical name of a _different_ agent only if that agent is not allowlisted in the channel.
- Aliases are configured per-agent from the agent's workspace admin channel, alongside `allowedChannelIds`.

**Alias resolution in the Event Router** (runs after the existing `::agentname` extraction):

1. Extract `::reference` tokens as today.
2. Attempt exact name lookup in the agent registry (current behavior — unchanged).
3. If no exact match, perform a channel-scoped lookup: `channelAliasIndex[(channelId, reference)]`.
4. If found, treat the resolved agent as if its canonical name had been referenced — all downstream logic (session tracking, turn log, trace entries) uses the canonical name.
5. If still not found, discard the event as today.

Alias resolution is transparent: once resolved, nothing downstream is aware that an alias was used.

### Agent categories

Each agent category defines the process logic that handles execution:

- `category_tools`: an array of tool enum variants available to agents in this category. This type structure is also used when configuring agent tool permissions through Slack interactive components.
- LLM model selection strategy.
- Store-backed knowledge configuration (including skill documents).

**Phased implementation:**

- **v0.2**: Agent registry, `::` routing, admin agent process handler, `#onboarding`/`#custom` category stubs, Slack-only write surface.
- **v0.5 (implemented core path)**: `#canister` execution flow (Core + Internal Engine), workflow envelope grants/permits, workflow API callbacks (`milestone`/`complete`), credential cascade hardening, Agent Session, Channel History, and weekly reconciliation.
- **v0.6 (implemented)**: Workflow Catalog system, approval gate with Block Kit buttons and TTL timers, `BlockActionsHandler`, `AgentRunner` refactor, `TurnSuspensionService`/`TurnCompletionService` extraction, `EnvelopeProcessor`/`WorkflowRunner`/`CoreEmitter` extraction, internal-engine run-store maintenance timer.
- **v0.7 (planned)**: `#github` runtime execution via Actions + webhooks, richer Process Engine/Effect Applicator, and Store/embedding layers.
- **Future**: Full pluggable agent framework, `view_submission` interactive messages, auth tokens, cost optimization, and richer Store document conventions.

### Agent routing and round control

The **Agent Router** sits between Event Dispatch and agent process handlers.

**Pre-conditions (checked before routing begins):**

- The message must contain at least one **valid `::agentname` reference** — resolved against the agent registry at dispatch time. If no valid reference is found (e.g., the reference doesn't match any registered agent), the event is **discarded/skipped**. This prevents orphaned or malformed inter-agent messages from entering the routing loop.
- The request chain must not be force-terminated in `SessionsModel`. If the chain is marked terminated, the event is **discarded/skipped** without invoking any agent process.
- The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution.

Both conditions are checked at the event router level, before the Agent Router hands off to a category service.

When a message passes pre-conditions and references an agent:

1. Resolves the agent from the registry.
2. Selects the appropriate category service.
3. Passes the `userAuthContext` and session context to the service.
4. The service executes and posts a reply to Slack.

**Round tracking** (in `SessionsModel`):

- `roundCount` increments each time the router processes a new event in the same request chain.
- **Hard upper bound**: `MAX_AGENT_ROUNDS` (10, defined in Constants). Once this limit is reached, the session is force-terminated.
- **Invariant**: an agent process must never directly invoke another agent process. The "connection" is always a `postMessage` on Slack that triggers a new round through an event. This ensures every hop is auditable, traceable, and budget-checkable.

## Process Engine (Loop Engine) [planned]

### Process model

The Process Engine implements a pure functional step model: a process step is a pure function that takes the current process state and a triggering event and returns a list of effects. No state is mutated and no I/O is performed inside the step function.

For LLM-bound steps, context assembly is explicit: the step prepares a retrieval request that combines Agent Session context with external knowledge layers (core files, memory, and Store documents, including `skills/`). The embedding lookup and fetch are executed by effect handlers/wrappers, then fed back into the next step as inputs.

The **Effect Applicator** then executes the returned effects in order (see [Effect](#effect) for type definitions): `StateWrite` → `SlackPost` → `EventEmit` → `ProcessSuspend`. The `ts` returned by `SlackPost` is available to subsequent effects in the same batch.

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
- Prompt-time embedding retrieval (memory/core-files/Store docs) is executed via wrappers/effects and injected into the LLM call context for that step.
- Long-running external work (LLM calls, GitHub API calls) is mediated through effects, not inline awaits inside step functions.

## Concurrency and Await Safety

Internet Computer execution can interleave at `await` points.
Design rules (planned and recommended for any new code):

- Update process status to `running` before the first `await`.
- Wrap with try {} catch to log trap messages and keep history of trap logs for future audit.
- Make processes step-based with logged transitions at every await — if a trap occurs, completed steps are skipped and execution restarts at the failed step.

### Single-Suspension Turn Model

**Current**: Each turn supports exactly one active suspension at a time — either `#awaitingWorkflow` (workflow dispatched to the internal engine) or `#awaitingApproval` (waiting for human approval via Block Kit button). When the LLM emits multiple tool calls in one round and more than one would trigger a suspension, the tool executor stops after the first and fills remaining calls with a synthetic `{"notRun":true}` response. `SuspensionData` tracks a single `pendingToolCallId`; the LLM is expected to re-issue any blocked call on the next round.

The `#awaitingApproval` status carries extra fields alongside `SuspensionData`: `approvalCode`, `expiresAtNs`, and a mutable `timerId` (the `ApprovalTimer` ID, stored so it can be cancelled when the user responds before expiry). The `timerId` is set asynchronously after the timer is armed and updated in-place via `SessionModel.setApprovalTimerId`.

This single-suspension constraint is intentional: it keeps the `TurnStatus` state machine, approval UX, and workflow correlation tractable.

**Future — concurrent suspension** [planned]: lifting this restriction is a meaningful architectural investment. A complete solution requires, at minimum:

- **`TurnStatus` refactor**: replace the single suspension slot with a barrier map keyed by `toolCallId`, tracking each in-flight suspension's state and partial result independently.
- **Live message field**: the Slack status update must be restructured to show per-tool-call progress and surface partial results as each suspension resolves — a structural change to how Loops status messages are composed and updated.
- **Resumption model**: a deliberate choice between _wait-all_ (turn resumes only when every suspension completes; all-or-nothing approval semantics), _checkpoint-runner_ (each suspension resolves independently and feeds a partial result back into the LLM mid-turn), or _dynamic_ (the LLM explicitly signals when it wants to be resumed). Each approach carries distinct UX, failure, and cost trade-offs.
- **Timers and partial-result coalescing**: per-suspension timeouts, result buffering, and ordered re-injection into LLM history.
- **Suspension GC**: orphaned suspensions — a workflow that never completes, an approval that expires — need a timer-driven reaper with audit logging.

Ship single-dispatch-first; revisit when parallel suspension becomes a genuine use-case bottleneck.

## Timers and Scheduling

### Current

- Key-derivation cache clearing timer (30 days).
- Processed events cleanup timer (7 days): fails stale unprocessed events, purges old processed/failed events.
- Weekly reconciliation timer (7 days): user cache + channel membership reconciliation and anchor verification.
- Channel history prune timer (7 days): prunes entries older than retention window.
- Turn cleanup timer (7 days): hard-deletes old turns/traces and envelope records.
- Engine top-up timer (7 days): checks spawned internal-engine cycle balance and tops up when below threshold.
- **Approval TTL timer** (per-turn, one-shot): arms when a turn enters `#awaitingApproval`. Fires `resumeWithDenial("approval timed out")` if the user does not respond before the deadline. TTL timers are re-armed for all still-awaiting turns on every upgrade. See [src/control-plane-core/timers/approval-timer.mo](src/control-plane-core/timers/approval-timer.mo).
- **Internal-engine run-store maintenance timer** (7 days, inside internal-engine): prunes completed/failed run records via `recurringTimer`.
- Keep timer state minimal and upgrade-safe (store "next run time" and reschedule in `postupgrade`).

Relevant code: [src/control-plane-core/main.mo](src/control-plane-core/main.mo)

### Planned

- **Auth token purge timer**: periodic cleanup of expired tokens.
- **Session compaction timer**: periodic pass over agent sessions; compacts raw turns into summary layers when token budget thresholds are exceeded.
- **Process Engine timer**: kick the Process Engine step loop periodically.
- **Recurring task timer**: goal-monitoring, reporting, and dashboard alerts.
- **Workspace deletion cascading cleanup timer**: when a workspace is deleted, ensure all associated objects (agents, secrets, sessions, traces, stored documents) are cleaned up thoroughly. This will require an async cleanup queue to handle the cascade safely, retrying failed deletions and ensuring all cleanup operations succeed before removing the workspace from the registry.

## Tooling and Integrations

### Current

- **Control-plane function tool registry**: static, resource-gated. Includes `web_search`, workspace secret management tools, and `dispatch_workflow`. See [src/control-plane-core/agents/tools/function-tool-registry.mo](src/control-plane-core/agents/tools/function-tool-registry.mo).
- **Control-plane tool executor**: executes function tools selected by the admin loop and can return dispatch signals for engine handoff. The `WorkflowEngineHandler` processes `coreDirectives` (approval gate, pre-validation) before issuing envelopes.
- **Internal-engine workflow tool registry**: scope-based tool assembly — tools are selected dynamically from `scopeGrants` in the envelope, covering `workspace`, `agent`, `slack-queue`, and `session` operations. See [src/internal-engine/tools/tool-registry.mo](src/internal-engine/tools/tool-registry.mo).
- **Workflow API services**: `WorkflowApiService` (sync route + authz + permits) and `WorkflowAsyncEffectService` (Slack milestone/final posts + turn finalization + approval-gate LLM resume). See [src/control-plane-core/services/workflow-api-service.mo](src/control-plane-core/services/workflow-api-service.mo) and [src/control-plane-core/services/workflow-async-effect-service.mo](src/control-plane-core/services/workflow-async-effect-service.mo).
- **Workflow Catalog service**: parses `listWorkflows()` JSON, filters by scopes, and drives lazy cache refresh. See [src/control-plane-core/services/workflow-catalog-service.mo](src/control-plane-core/services/workflow-catalog-service.mo).
- **Approval system**: `ApprovalModel`, `ApprovalTimer`, and `BlockActionsHandler` together implement the human-in-the-loop approval gate. Block Kit Approve/Deny buttons are posted to Slack; `block_actions` callbacks are routed to `BlockActionsHandler` in a zero-delay timer (well within Slack's 3-second interactive-payload window). Response URL is used for ephemeral outcome messages without requiring a bot token.
- **Wrappers**: Slack wrapper and OpenRouter wrappers are implemented in both canister boundaries where needed.
- **Internal engine runner modules**: `WorkflowRunner` (multi-round LLM loop), `EnvelopeProcessor` (full run lifecycle), `CoreEmitter` (emits milestones/complete to Core), and `RunHelpers`. See [src/internal-engine/runner/](src/internal-engine/runner/).

### Planned

- **GitHubWrapper**: HTTP outcalls for workflow dispatch, workflow/run status queries, and repository metadata validation for runtime agents.
- **GitHubWebhookAdapter**: verifies and normalizes GitHub Actions lifecycle/result webhooks into internal events for session correlation.
- **SlackWrapper expansion**: broaden read/write coverage and interactive-message support while keeping wrapper as the single Slack I/O boundary.
- **Embedding retrieval pipeline**: at each LLM call, embed the active prompt and query indexes for memory, core files, and Store documents (optionally filtered by `path`, such as `/skills/**`); inject top findings into the turn context.
- **Embedding indexes**: maintain searchable embeddings for memory records, core files, and Store documents. Index updates happen asynchronously when source documents change.
- **Tool scoping**: keep grants/permits and userAuthContext checks aligned across control plane and runtime engines.
- **Category tools**: formalize per-category tool contracts and stricter runtime subsets while preserving `toolsState` telemetry.
- **Broader LLM tool surface**: additional file/memory/store/browser/MCP patterns remain planned once workflow-engine contracts stabilize.
- **Interactive Messages** (partial): `block_actions` is implemented for approval buttons. `view_submission` and richer configuration/onboarding UX remain future.
- Agents empowered with:
  - LLM internal tools (function calling).
  - Remote MCPs (planned).
  - Custom functions (run inside the canister).
  - Custom functions (run externally, lambdas, RPCs).
  - Deployed canisters with custom code.

## Secrets, API Keys, and Encryption

### Current

- Secrets are encrypted at rest per workspace using keys derived from ICP Threshold Schnorr signatures.
- Secret types: `#openRouterApiKey`, `#slackSigningSecret`, `#slackBotToken`, `#custom(Text)`.
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

## Observability and Impact Tracking [planned]

### Minimal baseline (recommended)

- Append-only audit log for admin actions (bounded).
- Agent turn trace provides full execution visibility per turn; delegation chains are reconstructable by walking `triggerTurnId`.
- Slack thread trace is the primary human-facing execution log, not a separate operator-only surface.
- Each turn's trace entries expose the full step-by-step record in Slack: which agent acted, which tools or sub-actions ran, what came back, what changed because of it, and where cost was incurred.
- The Slack UX may collapse or de-emphasize repeated, well-understood flows, but the full turn trace should remain expandable via attachments or "show more" patterns.
- Rich Slack traceability is part of correct operation, not just debugging support: it helps humans learn the agent's way of solving problems, suggest safer or more efficient alternatives, diagnose bugs, and understand cost outliers.
- Counters derivable from turn traces (no separate counters needed):
  - turns queued/running/succeeded/failed (by scanning turn status)
  - provider calls by model (count `#llmCall` trace entries)
  - tool invocations (count `#toolCall` trace entries)
  - agent round counts and force-termination rates
- Optional attribution links: turn → goal metric(s) it was intended to move.

## Cost Controls and Budgeting [planned]

### Policy-first approach

- Budgets should be enforced by policy checks before enqueuing tasks.
- Track spend/usage independently from policy so forks can swap billing models.
- Use conservative defaults: allowlists, per-workspace limits, and approvals for risky tools.
- Agent round tracking provides a natural cost boundary: the progressive classifier after round 10 ensures escalating scrutiny on long-running chains.

## Tool Output Contract

All tool handlers (`ToolCallOutcome`) and the `workflowApi` endpoint share a common response contract:

- **`#ok : Text`** — a structured JSON string containing meaningful result data.
- **`#err : Text`** — a structured JSON string of the form `{"type":"camelCaseIdentifier","message":"Human readable sentence."}`.
  - `type`: a stable, programmatic camelCase identifier (e.g. `"parseError"`, `"unauthorized"`, `"missingField"`).
  - `message`: a human-readable sentence describing what went wrong.
  - Plain strings are **never** acceptable in `#err` payloads.

The variant names `#ok`/`#err` align with the ICP `Result` pattern (not `#success`/`#error`).

## Error Handling and Retries [planned]

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
- Turn trace data lifecycle: truncated fields pre-computed at write time, raw originals always retained; context assembly uses raw fields for turns < 1h old and truncated fields for older turns; hard deletion of turns + traces after 3 months (`TURN_CLEANUP_RETENTION_NS`). Session summary layers are the permanent record.
- Read-only query responses never expose personal or sensitive data — only aggregated stats and resource summaries.

## Upgrade and Persistence Strategy

- Ensure timers are re-established after upgrades.
- Be aware of IC migration requirement, when changing any data type, you must define an upgrade function.
- The migration from Principal-based auth to Slack-derived identity is a clean break (no production state to migrate).

## Testing and Development

See [AGENTS.md](AGENTS.md) for build commands, test strategy, cassette usage, and local development setup.

## Deep Dives

- Controller layer: [src/control-plane-core/main.mo](src/control-plane-core/main.mo)
- Services: [src/control-plane-core/services](src/control-plane-core/services)
- Wrappers and outcalls: [src/control-plane-core/wrappers](src/control-plane-core/wrappers)
- Event system: [src/control-plane-core/events](src/control-plane-core/events)
- Control-plane tools: [src/control-plane-core/agents/tools](src/control-plane-core/agents/tools)
- Approval gate: [src/control-plane-core/models/approval-model.mo](src/control-plane-core/models/approval-model.mo), [src/control-plane-core/timers/approval-timer.mo](src/control-plane-core/timers/approval-timer.mo), [src/control-plane-core/events/handlers/block-actions-handler.mo](src/control-plane-core/events/handlers/block-actions-handler.mo)
- Workflow catalog: [src/control-plane-core/models/workflow-catalog-model.mo](src/control-plane-core/models/workflow-catalog-model.mo), [src/control-plane-core/services/workflow-catalog-service.mo](src/control-plane-core/services/workflow-catalog-service.mo), [src/control-plane-core/types/workflow-catalog.mo](src/control-plane-core/types/workflow-catalog.mo)
- Workflow envelope: [src/control-plane-core/models/workflow-envelope-model.mo](src/control-plane-core/models/workflow-envelope-model.mo)
- Agent runner: [src/control-plane-core/agents/agent-runner.mo](src/control-plane-core/agents/agent-runner.mo)
- Internal-engine runtime: [src/internal-engine](src/internal-engine)
- Internal-engine runner modules: [src/internal-engine/runner](src/internal-engine/runner)
- Internal-engine tools: [src/internal-engine/tools](src/internal-engine/tools)
- Workflow catalog (engine side): [src/internal-engine/workflows/workflow-catalog.mo](src/internal-engine/workflows/workflow-catalog.mo)
- Models: [src/control-plane-core/models](src/control-plane-core/models)
- Cassette system: [tests/lib](tests/lib) and [tests/cassettes](tests/cassettes)

## Open Questions

- What is the initial tool allowlist and approval workflow?
- What concurrency and timeout policies should govern GitHub Coding Agent sessions per workspace/agent?
- What is the reconciliation strategy when an agent repository/workflow is changed or deleted outside the control plane?
