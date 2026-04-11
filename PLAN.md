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

## Plan: v0.5 — GitHub Coding Agent Foundation

**TL;DR**: Pivot the `#runtime` agent execution path from OpenClaw/Codespaces to GitHub Coding Agents, enforce per-agent channel security boundaries, and stand up the webhook ingress required to receive GitHub Actions lifecycle callbacks. These three PRs lay the foundation for the full v0.5 scope (dispatch, session correlation, Store, and Process Engine) without tackling those larger architectural pieces yet.

---

### 5.1 — Runtime Type Migration: OpenClaw → GitHub Coding Agent

**Goal**

Replace the v0.3-era `#runtime(#openClaw)` execution type with `#runtime(#githubCodingAgent)` as described in ARCHITECTURE.md. After this task the agent model, parsers, tool schemas, and router error messages all reference the new GitHub Coding Agent runtime — but no actual dispatch or webhook handling is implemented yet (that comes in 5.3 and future tasks). The `#runtime` branch in `AgentRouter` remains a graceful "not yet supported" error until dispatch is wired up.

**Current State**

- `AgentExecutionType` has `#api : { model : Text }` and `#runtime : RuntimeAgentConfig`.
- `RuntimeAgentConfig = { hosting : HostingConfig; framework : AgentFrameworkConfig }` with `HostingConfig = #codespace` and `AgentFrameworkConfig = #openClaw : { deployedVersion : ?Text }`.
- Agent parser (`agent-parsers.mo`) serialises/deserialises `#runtime` as `{ type: "runtime", hosting: "codespace", framework: "openClaw" }`.
- Tool schemas (`function-tool-registry.mo`) for `register_agent` and `update_agent` expose `"hosting": "codespace"`, `"framework": "openClaw"` in the JSON schema.
- `AgentRouter` rejects `#runtime` with `"remote runtime not yet supported"`.

**Desired State**

- `RuntimeAgentConfig` replaced by a flat variant:

  ```motoko
  public type AgentExecutionType = {
    #api : { model : Text };
    #runtime : RuntimeType;
  };
  public type RuntimeType = {
    #githubCodingAgent : GitHubCodingAgentConfig;
  };
  public type GitHubCodingAgentConfig = {
    repoFullName : Text; // "owner/repo"
    workflowFile : Text; // e.g. "agent.yml"
    ref : Text; // branch or tag, e.g. "main"
  };

  ```

- Agent parsers serialize/deserialize as `{ type: "runtime", runtime: "githubCodingAgent", repoFullName, workflowFile, ref }`.
- Tool schemas updated accordingly (register_agent, update_agent, fork_agent).
- `AgentRouter` still returns a graceful error for `#runtime` — text updated to reference GitHub Coding Agents.
- Agent model migration function handles the type change for any pre-existing `#runtime` records (maps old OpenClaw config to a sensible default GitHub Coding Agent config — or marks them as needing reconfiguration).
- All existing tests updated or adapted for the new type shape.

**Source Steps**

1. `models/agent-model.mo` — Replace `RuntimeAgentConfig`, `HostingConfig`, `AgentFrameworkConfig` with `RuntimeType` and `GitHubCodingAgentConfig`. Update `AgentRecord` field type. Update `register`, `updateById`, `forkAgent` to accept the new shape.
2. `tools/handlers/parsers/agent-parsers.mo` — Update `executionTypeToJson` and `parseExecutionType` for the new variant.
3. `tools/function-tool-registry.mo` — Update JSON schema strings for `register_agent`, `update_agent`, and `fork_agent` tool definitions.
4. `tools/handlers/agents/register-agent-handler.mo` — Update parsing of `executionType` input.
5. `tools/handlers/agents/update-agent-handler.mo` — Update parsing of `executionType` input.
6. `events/agent-router.mo` — Update the `#runtime` rejection message.
7. `agents/admin/org-admin-agent.mo`, `agents/planning/work-planning-agent.mo` — Update `executionType` switch arms (cosmetic, no logic change).
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Update unit tests for agent parsers: round-trip serialization of `#runtime(#githubCodingAgent { ... })`.
- Update unit tests for register-agent-handler and update-agent-handler: valid and invalid `executionType` payloads.
- Update integration test cassettes if the tool schema changes affect LLM request bodies (use `ignoreBodyFields` match rules where appropriate).
- Verify all existing tests still pass with the new type shape.

---

### 5.2 — Agent Channel Allowlist

**Goal**

Add a per-agent Slack channel allowlist (`allowedChannelIds`) to the agent model and enforce it in the `AgentRouter` before dispatching to any category service. When a message references an agent outside its allowed channels, the router blocks execution and posts an automatic warning to Slack. Agents with an empty allowlist are unrestricted (backward-compatible default).

**Current State**

- `AgentRecord` has no `allowedChannelIds` field — agents respond to `::` references in any channel.
- `AgentRouter` checks execution type and category/context match but has no channel guard.
- ARCHITECTURE.md specifies: "The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution."

**Desired State**

- `AgentRecord` gains `allowedChannelIds : [Text]` — a list of Slack channel IDs where the agent is permitted to run. Empty list = unrestricted (no breaking change for existing agents).
- `AgentRouter.route()` gains a pre-dispatch guard: if `allowedChannelIds` is non-empty and the message's channel ID is not in the list, return an error with the allowed channels listed. Optionally post a Slack message warning the user.
- `register_agent` and `update_agent` tool schemas include `allowedChannelIds` as an optional array of channel ID strings.
- `get_agent` and `list_agents` tool responses include `allowedChannelIds`.
- `forkAgent` copies `allowedChannelIds` from the original (can be overridden after fork via `update_agent`).

**Source Steps**

1. `models/agent-model.mo` — Add `allowedChannelIds : [Text]` to `AgentRecord`. Update `register`, `updateById`, `forkAgent`, and the v-migration shape.
2. `tools/handlers/parsers/agent-parsers.mo` — Serialize/deserialize `allowedChannelIds` in agent JSON output.
3. `tools/function-tool-registry.mo` — Add `allowedChannelIds` to `register_agent` and `update_agent` JSON schemas.
4. `tools/handlers/agents/register-agent-handler.mo` — Parse and pass `allowedChannelIds` (default to `[]`).
5. `tools/handlers/agents/update-agent-handler.mo` — Parse optional `allowedChannelIds` update.
6. `tools/handlers/agents/get-agent-handler.mo`, `list-agents-handler.mo` — Include `allowedChannelIds` in output.
7. `events/agent-router.mo` — Add channel allowlist guard before the execution-type switch. The guard receives the Slack channel ID from the event context, checks it against `primaryAgent.allowedChannelIds`, and short-circuits with an error if not allowed.
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (agent-model): register an agent with `allowedChannelIds = ["C123"]`, confirm field persists. Update to `["C123", "C456"]`, confirm update.
- Unit test (agent-router): route a message from channel "C123" to an agent with `allowedChannelIds = ["C123"]` → succeeds. Route from "C999" → blocked with error listing allowed channels. Route to an agent with `allowedChannelIds = []` from any channel → succeeds (unrestricted).
- Unit test (register-agent-handler): parse payload with and without `allowedChannelIds`.
- Integration tests: existing talk tests continue to pass because pre-seeded agents have `allowedChannelIds = []` (unrestricted).

---

### 5.3 — GitHub Webhook Ingress + Adapter

**Goal**

Stand up a new webhook endpoint (`/github/webhook` on `http_request_update`) that verifies GitHub HMAC-SHA256 signatures, parses GitHub Actions webhook payloads, and normalizes them into internal events. This is the receive side of the GitHub Coding Agent roundtrip — no dispatch yet, just ingress and event creation. The endpoint handles `workflow_run` and `workflow_job` events from GitHub Actions.

**Current State**

- `SlackAdapter` handles `/webhook/slack` with Slack-specific HMAC-SHA256 verification.
- `http_request_update` in `main.mo` routes only to `SlackAdapter`.
- `#githubWebhookSecret` already exists in `SecretId` (added in v0.3).
- No GitHub adapter, no `/github/webhook` route, no GitHub event types in `normalized-event-types.mo`.

**Desired State**

- New `events/github-adapter.mo` module:
  - `verifySignature(body : Blob, signatureHeader : Text, secret : Text) : Bool` — HMAC-SHA256 verification using `X-Hub-Signature-256` format (`sha256=<hex>`).
  - `parseWebhook(body : Blob, eventTypeHeader : Text) : Result<NormalizedEvent, Text>` — Parses GitHub webhook JSON based on the `X-GitHub-Event` header value. Supported events: `workflow_run` (completed, requested, in_progress), `workflow_job` (completed).
- New event variants in `normalized-event-types.mo`:

  ```motoko
  #githubWorkflowRun : {
    action : Text; // "completed" | "requested" | "in_progress"
    workflowRunId : Nat;
    workflowName : Text;
    headBranch : Text;
    conclusion : ?Text; // "success" | "failure" | "cancelled" | etc.
    repoFullName : Text;
    senderLogin : Text;
  };

  ```

- `main.mo` `http_request_update` gains a `/github/webhook` route that:
  1. Retrieves the `#githubWebhookSecret` from org workspace (ws 0).
  2. Calls `GitHubAdapter.verifySignature`.
  3. Calls `GitHubAdapter.parseWebhook`.
  4. Enqueues the resulting event in `EventStoreModel`.
- `EventRouter` gains a stub handler for `#githubWorkflowRun` that logs the event and marks it processed (no business logic yet — session correlation comes in a future task).

**Source Steps**

1. `events/types/normalized-event-types.mo` — Add `#githubWorkflowRun` variant to `NormalizedEvent`.
2. New file: `events/github-adapter.mo` — Signature verification + webhook parsing.
3. `main.mo` — Add `/github/webhook` route in `http_request_update`, wire to `GitHubAdapter`.
4. `events/event-router.mo` — Add `#githubWorkflowRun` case that logs and marks event processed.
5. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (github-adapter): valid HMAC passes, invalid HMAC fails. Parse a `workflow_run` completed payload → correct `NormalizedEvent` fields.
- Integration test: POST to `/github/webhook` with a valid signature → 200, event appears in event store. POST with invalid signature → 401.
- Integration test: POST with unsupported event type → graceful skip (200, event not enqueued).
- Existing Slack webhook tests unaffected (different route).

---

## Decisions

- **3 focused PRs** rather than the full v0.5 scope. The remaining v0.5 items (GitHub dispatch via `workflow_dispatch`, session correlation, Store model, Process Engine + Effect Applicator) build on this foundation and will be planned after these land.
- **OpenClaw → GitHub Coding Agent migration first** (5.1) because it's a type-level prerequisite that touches many files — better to land it cleanly before adding new features on top.
- **Channel allowlist second** (5.2) because it's an independent, high-value security boundary that can be reviewed and merged without waiting for GitHub integration work.
- **GitHub webhook ingress third** (5.3) because it needs the updated runtime types from 5.1 and establishes the receive half of the GitHub roundtrip.
- **Empty allowlist = unrestricted**: backward-compatible default so existing agents and tests don't break.
- **Stub handler for GitHub events**: 5.3 only wires ingress + event creation. Session correlation and dispatch are separate future tasks — keeps the PR small and reviewable.
