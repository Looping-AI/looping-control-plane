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

## Plan: v0.3 — Codespaces, OpenClaw, and Secrets Hardening

**TL;DR**: Evolve from a Slack-only canister with embedded LLM calls to a platform that manages remote AI agents running in GitHub Codespaces via OpenClaw. The canister becomes the control plane: it manages codespace lifecycles (via GitHub Device Flow + Codespaces API), pushes agent configurations to OpenClaw instances (via an Express sidecar), receives structured agent responses (via a new webhook endpoint), and orchestrates the final Slack replies. Simultaneously, refactor from Groq to OpenRouter as the canister’s own LLM provider, harden the secrets system with audit trails, and introduce a flexible credential cascade with custom secret types.

---

## Phase A — Foundation Refactors (no new features, unblocks everything)

### A.0 — Agent Execution Types

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

### A.1 — Refactor Groq → OpenRouter

**What**: Replace Groq API integration with OpenRouter. Same OpenAI-compatible chat completions API, same model (`openai/gpt-oss-120b` via Groq provider on OpenRouter).

**Changes**:

- `types.mo`: Replace `LlmProvider = #openai | #groq` → `#openRouter`. Add `#openRouterApiKey` to `SecretId`. Remove `#groqApiKey` from `SecretId` and `OrgCriticalSecretId`.
- `constants.mo`: `ADMIN_TALK_PROVIDER = #openRouter`, `ADMIN_TALK_SECRET = #openRouterApiKey`.
- Rename `groq-wrapper.mo` → `openrouter-wrapper.mo`. Update API URL from `api.groq.com` → `openrouter.ai/api/v1`. Update headers (add `HTTP-Referer`, `X-Title` per OpenRouter docs). Keep request/response types (OpenAI-compatible). Confirm `CompoundChatCompletionRequest` search settings work or adapt for OpenRouter’s native web search.
- `agent-model.mo`: `LlmModel = #openRouter(OpenRouterModel)`, `OpenRouterModel = #gpt_oss_120b`. Update `llmModelToText` and `llmModelToSecretId`.
- Update all references across agents, orchestrators, services.
- Pre-seeded agent: secretsAllowed changes to `#openRouterApiKey`.

**Verification**: `icp build control-plane-core`, re-record integration test cassettes with OpenRouter.

### A.2 — Secrets Hardening: Changelog + Access Log

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

### A.3 — Custom Secret Types + Credential Cascade

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
