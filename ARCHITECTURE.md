# Architecture

This is a living document. It focuses on design intent, invariants, rationale, and links to code for implementation details.

## Purpose

This repo is meant to be forked and adapted to personal or organizational use.
The long-term goal is an autonomous agent system that behaves like a teammate or coach: it can ingest requests and events, plan work, run tasks via tools/LLMs, measure impact against goals, and manage cost trade-offs.

## Reading Guide

Read through “Core Flows” for a high-level view of what exists today and where the design is headed. After that, the document becomes more technical and is most useful when you’re changing or debugging a specific subsystem (timers, encryption, wrappers, or tests). “Deep Dives” links you directly to the implementation files for quick reference.

## Key Goals

- Keep a small, understandable core that forks can extend.
- Make authorization and policy explicit at the controller and data classes layers.
- Make long-running work asynchronous via queued tasks (avoid doing heavy work inside request handlers).
- Track impact and cost with enough structure to support later attribution and budgeting.
- Be safe-by-default: secrets encrypted at rest, minimal trust in event sources, conservative tool access.

## Non-Goals (for now)

- Consolidated org billing and complex cost sharing.
- Multi-canister “enterprise” topology (root/main/frontend) as a requirement.
- Guaranteed perfect autonomy; humans remain in the loop via goals, policies, and approvals.
- Comprehensive compliance/regulatory features (these can be fork-specific).

## System Overview

### Current implementation (today)

- Single Motoko backend canister that exposes admin/agent/conversation/API-key methods.
- LLM provider integration via HTTP outcalls (currently Groq).
- API keys are encrypted at rest using a per-caller derived key.

Primary code entrypoint: [src/open-org-backend/main.mo](src/open-org-backend/main.mo)

### Target direction (what this architecture file plans for)

- A workspace model (personal/team/org) with policies, goals, budgets, and tools per workspace.
- Agents become empowered with a configurable tool layer.
- A task queue with a scheduler/runner driven by timers and admin calls.
- External integrations (Slack/email/etc.) mapped into normalized events.

## Architecture Principles

- Separation of concerns:
  - Controller layer: authentication/authorization/validation, policy checks, and orchestration.
  - Services: deterministic state transitions and reusable business logic.
  - Wrappers: encapsulation of external calls (LLMs/APIs), so integration changes and cross actions live in one place.
- “Plan fast, execute later”: request handlers should enqueue tasks instead of running long operations.
- LLMs will use Policies, Tools and Knowledge as a flexible way to execute tasks, and will only code them as they become more frequent and easier to standardize.
- Have explicit approval flows, guard-rails, for context control, without micro-managing (tool access, spending limits, any other custom approval defined in a Policy).
- Mixture of agents is desired as a strategy (Lower input/context window, easier A/B testing for cost/quality optimizing, lower risk on model upgrading).
- Auditable: the system should be auditable (events and conversation history).
- Avoid LLM Obedience: be resilient to prompt injection and spoofed events (Through Caller signature-checks, Data Classes and Policies).

## Core Concepts

### What exists now

- Admins: principals that can manage agents. See [src/open-org-backend/main.mo](src/open-org-backend/main.mo).
- Agents: named config objects that select provider + model.
- Conversations: per-caller, per-agent message history.
- API keys: encrypted per (caller, agent, provider).

### What is planned

- Workspace: a unit of policy, goals, knowledge and shared state.
- Policies: text based rules for what is allowed or not.
- Tasks: queued work items that may involve awaits (LLM calls, tool use, function calling).
- Events: normalized inbound signals (integration callbacks, metrics, triggers).

## External Interfaces

### Canister API

- Current: admin/agent management, `talkTo`, conversation history, and API key storage.
- Planned: `adminTalk(workspaceId, ...)`, `workspaceTalk(workspaceId, ...)`, `handleEvents(workspaceId, ...)`, and `runTasks(?workspaceId)`.

### Integrations (planned)

- Chat systems (Slack, etc.)
- Email
- Internal/external tool APIs

## Core Flows

### Current: chat with an agent

- Caller stores provider API key (encrypted at rest).
- Caller calls `talkTo(agentId, message)`.
- Canister derives caller encryption key (cached), reads API key, calls provider wrapper, and appends conversation messages.

### Planned: three main controller functions

- `adminTalk(...)` and `workspaceTalk(...)` (request intake)
  - Authz + policy checks
  - Parse/route intent
  - Enqueue one or more tasks
  - Reply quickly with an acknowledgement and/or a short plan

- `handleEvents(...)` (external callback intake)
  - Authenticate event source where possible
  - Normalize events into internal representation
  - Enqueue tasks (often lightweight bookkeeping + maybe follow-up work)

- `runTasks(...)` (task runner)
  - Triggered by admin calls and/or timers
  - Executes pending tasks with await-safe status updates and idempotency

## State Model

### Current

See the persistent state variables in [src/open-org-backend/main.mo](src/open-org-backend/main.mo).

- Agents map + next agent id
- Admin list
- Conversations map
- API keys map (encrypted values)
- Transient key-derivation cache + timestamp used for timer scheduling

### Planned (scalable shape)

- `workspaces`: `workspaceId -> WorkspaceState`
- `policies`: `workspaceId -> Policy`
- `tasks`: `taskId -> TaskState` plus per-workspace task indexes
- `events`: optional per-workspace event log (bounded)
- `metrics`: counters/time-series summaries for cost and goal progress

Design note: prefer a single flexible “workspace” abstraction rather than hardcoding “org/team/personal”.

## Identity, Roles, and Authorization

### Current

- Anonymous callers are rejected for most shared methods.
- A simple “admins list” gates agent management.

### Planned

- Roles are per-workspace: role bindings live under a workspace.
- Suggested minimal roles:
  - Owner (administrative control, Admins of the parent Workspace)
  - Admin (manage policies, agents, budgets)
  - Member (request work, view results)
  - Integration (non-human principals used by adapters)
- Policies and effective guard-rails.

## Task Execution Model

### Task lifecycle (planned)

- `queued -> running -> {succeeded | failed | cancelled}`
- Retry states with exponential backoff and maximum attempts.
- Each task stores:
  - workspace id
  - initiator principal
  - capabilities snapshot (tool allowlist + budget ceilings at enqueue time)
  - idempotency key (to dedupe duplicate events)
  - audit metadata (timestamps, attempt count, last error)

### Execution responsibility

- `talkTo` and `handleEvents` should avoid long awaits; they should enqueue tasks.
- `runTasks` owns long-running work (LLM calls, tool execution, external I/O).

## Concurrency and Await Safety

Internet Computer execution can interleave at `await` points.
Design rules (planned and recommended for any new code):

- Update task status to `running` before the first `await`.
- Wrap with try {} catch to log trap messages and keep history of trap logs for future audit.
- Make tasks step based and logged on every await that succeeds, ensuring that if a trap happens, it skips the successful steps and restarts on the failed step.

## Timers and Scheduling

### Current

- A timer clears the transient key-derivation cache and is re-established after upgrade.
- Keep timer state minimal and upgrade-safe (store “next run time” and reschedule in `postupgrade`).

Relevant code: [src/open-org-backend/main.mo](src/open-org-backend/main.mo)

### Planned

- Use timers to:
  - kick `runTasks` periodically
  - run recurring Tasks, like goal-monitoring and reporting tasks
  - dashboard, performance monitoring and actions (alerts, task canceling)

## Tooling and Integrations

### Current

- Provider wrappers are the boundary for HTTP outcalls.

### Planned

- A “tool registry” per workspace: allowlist, rate limits, and cost estimates.
- Integration adapters translate external payloads into normalized events.
- Agents empowered with the use of:
  - LLM internal tools
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

- API keys are encrypted at rest.
- A per-caller encryption key is derived and cached transiently.

Deep dive entrypoints:

- [src/open-org-backend/services/api-keys-service.mo](src/open-org-backend/services/api-keys-service.mo)
- [src/open-org-backend/services/key-derivation-service.mo](src/open-org-backend/services/key-derivation-service.mo)

### Planned

- Adapt to workspace logic: allow a talkTo event or task execution to use the associated workspace keys (but still log who was the caller).

## Observability and Impact Tracking

### Minimal baseline (recommended)

- Append-only audit log for admin actions (bounded).
- Counters for:
  - tasks queued/running/succeeded/failed
  - provider calls (by provider/model)
  - error categories
- Optional attribution links: task -> goal metric(s) it was intended to move.

## Cost Controls and Budgeting

### Policy-first approach (planned)

- Budgets should be enforced by policy checks before enqueuing tasks.
- Track spend/usage independently from policy so forks can swap billing models.
- Use conservative defaults: allowlists, per-workspace limits, and approvals for risky tools.

## Error Handling and Retries

- Retries belong in the task runner, not in intake handlers.
- Distinguish:
  - deterministic validation errors (do not retry)
  - transient provider/network errors (retry with backoff)
  - quota/budget errors (do not retry; require policy change)

## Data Retention and Privacy

- Conversations and events should be bounded (size and/or time) to avoid unbounded state growth.
- Consider per-workspace retention policies.
- Avoid storing raw external event payloads longer than needed; store normalized summaries.

## Upgrade and Persistence Strategy

- Ensure timers are re-established after upgrades.
- Be aware of IC migration requirement, when changing any data type, you must define an upgrade function.

## Testing Strategy

- Motoko unit tests for pure services.
- TypeScript tests (PocketIC) for canister API behavior and any Unit Test that needs Cassettes (Mocked HTTP Outcalls).

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
- Cassette system: [tests/lib](tests/lib) and [tests/cassettes](tests/cassettes)

## Glossary

- Workspace: a unit of policy, access, budget and goals.
- Policy: declarative constraints over any task, tools, budgets, and permissions.
- Task: queued work item executed asynchronously.
- Event: normalized inbound signal from an integration or internal trigger.

## Open Questions

- What is the minimal workspace model that covers personal + team without forcing org complexity?
- How should organization ownership transfer work (human process and technical safeguards)?
- Which metrics define “impact” for the first real use case (and how are they measured)?
- What is the initial tool allowlist and approval workflow?

## Future Work

- Introduce `handleEvents` and `runTasks` and move long-running work out of `talkTo`.
- Add workspaces with scoped policies and roles.
- Add a task queue with leases, idempotency keys, and backoff.
- Add impact/cost tracking primitives (counters + task-to-goal attribution).
