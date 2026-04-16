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

## Plan: v0.5 — Agent Allowlist + Execution Engines + Filesystem

**TL;DR**: Remove the obsolete agent-forking feature (5.0), enforce per-agent channel security boundaries (5.1), introduce the Execution Engine abstraction with the Effect Applicator to cleanly separate envelope construction, engine dispatch, and result application (5.2), then build the Filesystem — a file-like persistent knowledge layer that each agent owns exclusively and can read from and write to (5.3 + 5.4). The Execution Engine refactor establishes the envelope-in/package-out contract that makes future engine types (`#canister`, external HTTP) pluggable without changing the orchestrator. The Filesystem feature is split across two PRs: first the data model + admin tools, then the agent-facing `file_read`/`file_write` tools. GitHub integration is deferred to a later version.

---

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

---

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

### 5.2 — Execution Engines + Effect Applicator

**Goal**

Introduce the Execution Engine abstraction — a clean boundary between _deciding what to execute_ (envelope construction), _executing it_ (engine dispatch), and _applying the results_ (effect application). Refactor the current inline LLM-loop-to-Slack-post pipeline into three phases:

1. **Envelope construction** — The orchestrator assembles a typed `ExecutionEnvelope`: fully assembled messages, instructions, execution constraints, and resolved credentials. The envelope is a data-only payload — it never contains code references, tool executors, or LLM wrappers. Think of it as the JSON body of an HTTP POST request.
2. **Engine dispatch** — The envelope is handed to the selected execution engine. For `#internal` (this PR), the engine is a self-contained module that runs the multi-round LLM tool loop in-canister. The engine owns its own tool registry, LLM model selection, and execution strategy — the control plane does not dictate these. It returns a sealed `ExecutionPackage`: complete trace, final response, aggregated stats, and terminal status.
3. **Effect application** — The `EffectApplicator` receives the Package and executes all post-execution side effects: persisting traces, posting the Slack reply, finalizing the turn, and emitting follow-up events.

Only the `#internal` engine is implemented in this PR (in-canister LLM loop, mirroring the existing flow). The abstraction makes `#canister` and external engines pluggable in future PRs without touching the orchestrator or applicator.

**Current State**

- The LLM tool loop lives inside `org-admin-agent.mo` (`process()`) — it directly calls OpenRouter, executes tools, appends traces to the session model, and hands the response back to the message handler which posts the Slack reply.
- No separation between execution and side effects: LLM calls, tool calls, trace writes, and Slack posting are interleaved across the message handler and agent module.
- `config.executionEngines` exists in the agent record but only `#api` is functionally used, with no engine interface. (Will be renamed to `#internal`.)
- `agent-orchestrator.mo` is a pass-through: scopes workspace data, decrypts secrets, delegates to the agent module.
- Context assembly (`context-assembler.mo`) and instruction composition (`instruction-composer.mo`) are coupled to the admin agent code path.

**Desired State**

- **`ExecutionEnvelope`** — Typed, self-contained, data-only input to any execution engine:
  - `envelopeVersion : Nat` — schema version of this envelope format. The engine may reject envelopes it doesn't support and reply with the version it expects, enabling auto-corrective version negotiation.
  - `requestId : Text` — correlates the envelope to its package.
  - `agentId : Nat`, `agentName : Text`, `workspaceId : Nat`.
  - `workflowId : Text` — identifies which workflow the engine should execute (e.g., `"admin-v1"`, `"onboarding-v1"`). The engine advertises available workflow IDs via `availableWorkflows` in the Package; the control plane picks one per request. The engine owns what each workflow means (tools, model, strategy).
  - `messages : [ChatMessage]` — fully assembled context (session memory, channel history, user prompt).
  - `instructions : Text` — composed system prompt (all instruction layers merged).
  - `constraints : { maxRounds : Nat; maxTokenBudget : ?Nat }` — execution limits.
  - `secrets : { apiKeys : [(Text, Text)] }` — resolved credentials the engine needs (e.g., LLM provider API keys). For `#internal` these are static copies passed as params; for external engines they are serialized into the envelope payload.

  The envelope does **not** contain tool definitions, LLM model selection, or agent category. Those are the engine's responsibility — each `workflowId` encapsulates a specific combination of tools, model, and execution strategy managed entirely by the engine.

- **`ExecutionPackage`** — Typed, self-contained output from any execution engine:
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
  - The control plane tracks, per execution engine, the latest `envelopeVersion` it sends and the latest `packageVersion` it has received.
  - If an external engine rejects an envelope (e.g., schema too old or too new), it replies with the `envelopeVersion` it expects in the rejection body. The control plane records this and retries with the requested version. This allows engines to evolve independently — different engines can be at different envelope versions at the same time.
  - Similarly, the `packageVersion` field in every Package tells the control plane which schema to use for parsing. The control plane maintains parsers for all supported versions.
  - For `#internal`, version negotiation is compile-time — the engine and control plane share the same type definitions and always agree.

**Design Notes**

- **The `#internal` engine is pure.** Only `main.mo` owns the persistent data structures. The envelope is assembled from static copies of state (messages, instructions, credentials) and passed as params to the engine. Since the engine receives copies — not references to `main.mo`'s data — any mutations the engine makes to its local params do not affect the canister's persistent state. All persistent side effects flow exclusively through the Effect Applicator after the engine returns the Package. This is the same guarantee an external engine provides by design (it can't reach the canister's state), achieved here through Motoko's value semantics.
- **The engine owns tools, model selection, and execution strategy via workflows.** The control plane tells the engine _what_ to do (instructions, context, constraints) and _which workflow_ to use (`workflowId`). The engine decides _how_ that workflow executes: which LLM to call, which tools to register, how to orchestrate the loop. For `#internal`, each workflow ID maps to a specific tool set + model combination. This means the tool registry, tool executor, and LLM wrapper live inside the engine module — they are not imported from the core codebase by the orchestrator.
- **Workflow versioning enables safe evolution.** An engine can introduce `"admin-v1.1"` alongside `"admin-v1"` without any control plane changes. The control plane sees the new ID in `availableWorkflows`, starts A/B testing, and gradually shifts traffic based on observed performance (cost, speed, user reviews). When the old version is retired, the engine drops it from the catalog and the control plane stops using it. No coordinated deploys, no breaking changes.
- **No trace mitigation needed for mid-execution traps.** If the engine traps (e.g., an HTTP outcall fails), local state from that IC message is rolled back and no Package is returned. From the Effect Applicator's perspective, no Package means no effects applied — the turn was never updated. The control plane's trace will show "envelope sent" (the dispatch happened) but no package received. Each execution engine is responsible for its own internal logging; the control plane does not attempt to recover partial engine state.
- **The Package is the atomic observability unit.** Every LLM call, tool call, and decision is captured in `package.trace`. The applicator uses this to build the Slack thread trace (the primary human-facing audit log). No separate trace-writing path exists outside the applicator.
- **Engine selection is trivial in this PR.** Only `#internal` exists. The orchestrator selects based on `agent.config.executionEngines[0]`, and uses the only available workflow from the engine's catalog. Future PRs add engine selection logic and workflow-level A/B testing.
- **Envelope construction owns all context assembly.** The envelope contains fully assembled messages — the engine never reaches back into session model or channel history. This makes the engine portable: the same `#internal` engine implementation works regardless of what assembled the envelope, and a future external engine receives a self-contained payload.
- **No `EngineContext` — the engine is fully self-contained.** The `#internal` engine module contains its own tool registry, tool executor, and LLM wrapper. It does not import these from the core codebase. The envelope carries everything the engine needs as data (messages, instructions, constraints, secrets, workflowId). For external engines, this is natural (the envelope is a POST body). For `#internal`, this means the engine module is a self-contained folder with no imports from `tools/`, `services/`, or `wrappers/` — only from `models/execution-types.mo` for the shared Envelope/Package types.
- **Versioned envelope and package formats.** `envelopeVersion` and `packageVersion` enable independent evolution of the control plane and its engines. An engine can reject an envelope version it doesn't support and tell the control plane which version to send. The control plane can parse any `packageVersion` it has seen. For `#internal` this is compile-time agreement; for external engines it enables rolling upgrades without coordinated deploys.

**Source Steps**

1. New file: `models/execution-types.mo` — `ExecutionEnvelope` (with `envelopeVersion`, `workflowId`), `ExecutionPackage` (with `packageVersion`, `availableWorkflows`), `ExecutionStats`, `PackageStatus`, `ExecutionConstraints` types. Minimal, no behavior — pure type definitions shared between the orchestrator and all engines.
2. New directory + file: `engines/internal/internal-execution-engine.mo` — `execute(envelope) → async ExecutionPackage`. Self-contained module with its own tool registry, tool executor, and LLM wrapper (OpenRouter). No imports from `tools/`, `services/`, or `wrappers/`. Reads `envelope.workflowId` to select the tool set + model. Calls OpenRouter, handles `#toolCalls`, accumulates traces in a local buffer, iterates up to `constraints.maxRounds`, seals the Package (including `availableWorkflows`) on completion/failure/round-limit. Initial workflows: `"admin-v1"` (admin tool set), `"onboarding-v1"` (stub, returns not-yet-implemented).
3. New file: `services/effect-applicator.mo` — `apply(processingContext, package) → async Result<(), Text>`. Writes `package.trace` to session model. Posts `package.response` to Slack via `SlackWrapper.postMessage`. Updates turn status (`#completed`/`#failed`) and cost aggregates. Emits follow-up events if needed.
4. Refactor `orchestrators/agent-orchestrator.mo` — Replace the direct `adminAgent.process()` call with: (a) assemble `ExecutionEnvelope` (context + instructions + constraints + secrets + workflowId from cached catalog), (b) dispatch envelope to selected engine, (c) update local workflow catalog from `package.availableWorkflows`, (d) pass Package to Effect Applicator.
5. Refactor `agents/admin/org-admin-agent.mo` — Transform `process()` into envelope assembly logic that returns an `ExecutionEnvelope`. What remains in the orchestrator path: instruction composition via `InstructionComposer`, context assembly via `ContextAssembler`, secret resolution, workflow selection from cached catalog. Tool assembly and LLM wrapper move into the `#internal` engine module.
6. Refactor `events/handlers/message-handler.mo` — Slack reply posting moves to the Effect Applicator (called through the orchestrator). The handler delegates to the orchestrator and receives the final result, no longer posts directly.
7. Rename `#api` → `#internal` in `agent-model.mo` (`ExecutionEngine` variant), agent registry, and all references.
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (execution-types): construct Envelope and Package values, verify all fields are correctly typed and accessible.
- Unit test (internal-execution-engine): mock LLM to return `#textResponse` → Package has `#completed` status with response. Mock LLM to return `#toolCalls` then `#textResponse` → Package trace contains both `#llmCall` and `#toolCall` entries in order. Mock LLM to loop `maxRounds` times → Package has `#roundLimitReached` status. Mock LLM to error → Package has `#failed` status with error message. Verify engine selects tools and model based on `workflowId` without external input. Verify `availableWorkflows` is always populated in the Package.
- Unit test (workflow catalog): send envelope with unknown `workflowId` → engine returns `#failed` with error + `availableWorkflows` listing valid IDs. Send envelope with valid `workflowId` → Package includes full `availableWorkflows` catalog.
- Unit test (effect-applicator): given Package with N trace entries → all N entries written to session model. Given Package with response text → `SlackWrapper.postMessage` called with correct channel/thread/content. Given Package with `#failed` status → turn marked as failed.
- Unit test (purity): pass an envelope to the engine, verify that the original envelope data is unchanged after execution (static copy guarantee).
- Integration test: full flow from Slack message → envelope build → `#internal` engine → Package → Effect Applicator → Slack reply + persisted session trace. Verify the Slack reply content and session trace entries match the execution.
- Regression: all existing admin-talk integration tests pass with no behavioral change (pipeline restructured, user-visible output identical).

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

- **4 focused PRs** covering the top priorities: channel security (5.1), then Execution Engines + Effect Applicator (5.2), then Filesystem in two phases (5.3 model + admin tools, 5.4 agent-facing tools).
- **Execution engines before filesystem** (5.2): the engine abstraction is a prerequisite for clean agent execution. Filesystem tools are wired through tool handlers that execute inside the engine — getting the engine boundary right first avoids retrofitting later.
- **Envelope/Package as the universal engine contract**: every engine type (`#internal`, `#canister`, external HTTP) receives an `ExecutionEnvelope` and returns an `ExecutionPackage`. The Envelope and Package structures are the same for all engines and all agent categories — admin, custom, onboarding all use the identical types. This makes engines swappable without changing the orchestrator or applicator. The envelope is data-only (never code); the engine never reaches back into the control plane's state.
- **`#internal` engine only in this PR**: the in-canister LLM loop is the only engine implemented. `#canister` (inter-canister dispatch with principal validation) and external HTTP engines (HMAC-signed) are future work. The abstraction supports them; the implementation doesn't need them yet.
- **The control plane decides _what_, the engine decides _how_ via workflows**: the envelope carries context, instructions, constraints, credentials, and a `workflowId`. The engine advertises a catalog of workflow IDs — each encapsulating a specific tool set, model, and execution strategy. The control plane picks a workflow per request. No tool definitions, model strings, or agent categories are sent in the envelope. New workflow versions can coexist for A/B testing; the control plane shifts traffic based on observed performance.
- **Reactive workflow catalog via `availableWorkflows`**: every engine response (Package, rejection, error) includes the full list of currently supported workflow IDs. The control plane caches this per engine and updates on every response. No polling or pull endpoint needed. When a workflow disappears from the catalog, the control plane stops using it. When a new one appears, it can start testing.
- **HMAC is engine-type-dependent, not universal**: `#internal` (in-canister) needs no signing — the Package never crosses a trust boundary. `#canister` uses caller principal validation. External engines use HMAC-SHA256 with a pre-shared secret. Signing in-memory data structures that never leave the canister would be security theater.
- **The `#internal` engine is pure.** The envelope is a static copy of data from `main.mo` — the engine cannot mutate the canister's persistent state. All persistent side effects (trace writes, Slack posts, turn finalization) flow through the Effect Applicator after the Package is returned. Tool execution happens inside the engine but operates on the engine's local state only; results are captured in the Package trace.
- **Package as atomic observability unit**: every LLM call, tool call, and decision point is captured in `package.trace`. The applicator uses this to persist session traces and build the Slack thread trace. No other trace-writing path exists.
- **Versioned envelope and package formats**: `envelopeVersion` and `packageVersion` enable independent evolution. An external engine can reject an envelope and reply with the version it expects, enabling auto-corrective negotiation. The control plane tracks the latest versions per engine. For `#internal`, versions are compile-time aligned.
- **No `EngineContext`**: the engine is fully self-contained. It owns its tool registry, tool executor, and LLM wrapper. The envelope carries all needed data (including secrets and `workflowId`). For `#internal`, the engine module is a self-contained folder with no imports from the core `tools/`, `services/`, or `wrappers/` directories — only from `models/execution-types.mo` for the shared types.
- **GitHub integration deferred**: Runtime type migration, webhook ingress, and Coding Agent dispatch are valuable but not the immediate priority. They'll be planned in a later version.
- **Agent allowlist first** (5.1) because it's the highest-priority security boundary — independent and self-contained.
- **Filesystem split into two PRs** because the full scope (model + admin tools + agent tools + wiring across all categories) is too large for one review. PR 5.3 delivers the foundation and admin management; PR 5.4 delivers the agent-facing tools that make the Filesystem useful in practice.
- **Agent-scoped filesystem, no cross-agent access**: each agent's filesystem is fully isolated. There is no shared filesystem, no cross-agent reads, and no admin-managed global knowledge base. If agents need to share knowledge, they do so through Slack messages. This enforces explicit, auditable communication.
- **No separate skill model**: skill documents are file entries under `/skills/` paths by convention, not a distinct data type. This keeps the persistence model unified.
- **`file_read`/`file_write` naming** follows ARCHITECTURE.md's planned tool list. They're the agent-facing API; admin CRUD tools use more explicit names (`create_file_entry`, etc.).
- **Minimum 1 channel required**: agents must always have at least one channel in their allowlist. The last channel cannot be removed. Channels can be added/changed, but the allowlist cannot be emptied.
- **Embedding-based search deferred**: `file_search` requires an embedding pipeline which is a separate effort. Agents use `file_read` with path prefixes for discovery in v0.5.
