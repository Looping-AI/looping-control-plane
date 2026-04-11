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

## Plan: v0.5 — Agent Allowlist + Store

**TL;DR**: Enforce per-agent channel security boundaries, then build the Store — a file-like persistent knowledge layer that each agent owns exclusively and can read from and write to. Every agent gets its own isolated store; there is no shared store between agents (sharing happens through Slack messages, not through the store). The Store is a large feature, so it's split across two PRs: first the data model + admin tools, then the agent-facing `file_read`/`file_write` tools wired into the LLM tool loop. GitHub integration is deferred to a later version.

---

### 5.1 — Agent Channel Allowlist

**Goal**

Add a per-agent Slack channel allowlist (`allowedChannelIds`) to the agent model and enforce it in the `AgentRouter` before dispatching to any category service. When a message references an agent outside its allowed channels, the router blocks execution and posts an automatic warning to Slack. Each agent must be registered with at least one channel in its allowlist; the allowlist cannot be emptied after registration.

**Current State**

- `AgentRecord` has no `allowedChannelIds` field — agents respond to `::` references in any channel.
- `AgentRouter` checks execution type and category/context match but has no channel guard.
- ARCHITECTURE.md specifies: "The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution."

**Desired State**

- `AgentRecord` gains `allowedChannelIds : Set<Text>` — a set of Slack channel IDs where the agent is permitted to run. Must contain at least one channel; cannot be emptied after registration.
- `AgentRouter.route()` gains a pre-dispatch guard: if the message's channel ID is not in the agent's `allowedChannelIds` set, it posts an automatic Slack warning listing the allowed channels and skips execution (no category service dispatch).
- `register_agent` and `update_agent` tool schemas include `allowedChannelIds` as an optional set of channel ID strings (input as array, converted to set).
- `get_agent` and `list_agents` tool responses include `allowedChannelIds`.
- `forkAgent` copies `allowedChannelIds` from the original (can be overridden after fork via `update_agent`).

**Source Steps**

1. `models/agent-model.mo` — Add `allowedChannelIds : Set<Text>` to `AgentRecord`. Update `register`, `updateById` and `forkAgent`.
2. `tools/handlers/parsers/agent-parsers.mo` — Serialize/deserialize `allowedChannelIds` in agent JSON output.
3. `tools/function-tool-registry.mo` — Add `allowedChannelIds` to `register_agent` and `update_agent` JSON schemas.
4. `tools/handlers/agents/register-agent-handler.mo` — Parse and pass `allowedChannelIds` (required, must contain at least one channel). Convert input array to set. Reject if empty.
5. `tools/handlers/agents/update-agent-handler.mo` — Parse optional `allowedChannelIds` update. Validate that the new set is not empty (reject attempts to remove the last channel).
6. `tools/handlers/agents/get-agent-handler.mo`, `list-agents-handler.mo` — Include `allowedChannelIds` in output.
7. `events/agent-router.mo` — Add channel allowlist guard before the execution-type switch. The guard receives the Slack channel ID from the event context, checks it against `primaryAgent.allowedChannelIds`, and short-circuits with an error if not allowed.
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (agent-model): register an agent with `allowedChannelIds = Set.fromArray(["C123"])`, confirm field persists. Update to `Set.fromArray(["C123", "C456"])`, confirm update. Attempt to create with empty set → error. Attempt to remove last channel → error.
- Unit test (agent-router): route a message from channel "C123" to an agent with `allowedChannelIds = Set.fromArray(["C123"])` → succeeds. Route from "C999" → blocked with error listing allowed channels. Attempt to remove the last channel → error (at least one required).
- Unit test (register-agent-handler): parse payload with valid `allowedChannelIds` (non-empty) → agent created. Parse payload with missing or empty `allowedChannelIds` → error.
- Integration tests: existing talk tests continue to pass by pre-seeding agents with appropriate `allowedChannelIds` during setup.

---

### 5.2 — Store: Data Model + Admin Tools

**Goal**

Introduce the Store — a file-like key-value persistence layer for structured and unstructured agent knowledge, scoped per agent. Each agent owns its own fully isolated store; no agent can read or write another agent's store. This phase builds the data model and wires admin-facing tools so the `::workspace-admin` agent can manage its own store entries. Agent-facing tools (`file_read`, `file_write`) come in 5.3.

**Current State**

- No Store model exists. ARCHITECTURE.md specifies Store as a `[planned]` concept.
- Agents have no persistent knowledge storage beyond session traces and channel history.
- `ToolResources` in `tool-types.mo` has no Store resource.
- Skill documents are planned as a Store subtype under `/skills/` paths but do not exist yet.

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
    createdBy : Text; // agent name
    updatedBy : Text; // agent name
  };

  ```

- Filesystem state: `FilesystemState = Map<Text, FileEntry>` keyed by `path`. Each agent holds its own `FilesystemState` instance — there is never a shared map across agents. All paths must start with `/`. The model normalizes non-absolute paths automatically (prepends `/`).
- Persistent global state in `main.mo`: `Map<Nat, FilesystemModel.FilesystemState>` keyed by agent ID. Each agent's `FilesystemState` is fetched by agent ID and passed as a resource; agents never see each other's instances.
- Model functions (state parameter first, per Motoko conventions):
  - `put(state, entry) → Result<FileEntry, Text>` — creates or updates an entry. Validates path format.
  - `get(state, path) → ?FileEntry` — retrieves a single entry by exact path.
  - `delete(state, path) → Result<FileEntry, Text>` — removes an entry, returns the deleted entry.
  - `list(state, pathPrefix) → [FileEntry]` — lists all entries whose path starts with `pathPrefix`. If prefix is `/`, returns all entries in the filesystem. If prefix is `/skills/`, returns only skill documents.
  - `listPaths(state, pathPrefix) → [Text]` — lightweight variant returning only paths (for directory-like browsing).
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
- Tools wired into `org-admin-agent.mo` via `FunctionToolRegistry` (admin category, write access). Admin agent manages its own filesystem only.
- Persistent state: `allFilesystemStates` added to `main.mo` as `Map<Nat, FilesystemModel.FilesystemState>` (keyed by agent ID). The current agent's `FilesystemState` is extracted by ID and passed through `EventProcessingContext` → `AdminAgentCtx`.

**Design Notes**

- **Agent-scoped and isolated**: each agent owns its own `FilesystemState` instance. There is no shared filesystem — agents cannot read or write each other's files. If an agent needs to share knowledge, it does so through Slack messages, not through the filesystem.
- **Path uniqueness**: paths are unique within a single agent's store. `put` overwrites on same path; `create` rejects duplicates.
- **No content-size limit enforced in v0.5**: the IC's stable memory limits apply naturally. A future task may add explicit limits.
- **Skills are just file entries**: no separate skill model. Skill-specific conventions (e.g., `/skills/<id>/SKILL.md`) are enforced by convention in tool descriptions, not by the model.

**Source Steps**

1. New file: `models/filesystem-model.mo` — `FileEntry` type (no `workspaceId`), `FilesystemState` type alias, `put`, `get`, `delete`, `list`, `listPaths`, path normalization utility.
2. `tool-types.mo` — Add `filesystem` field to `ToolResources` (no `workspaceId`, no `agentId` — the state is already agent-resolved).
3. New files: `tools/handlers/filesystem/create-file-entry-handler.mo`, `update-file-entry-handler.mo`, `get-file-entry-handler.mo`, `list-file-entries-handler.mo`, `delete-file-entry-handler.mo`.
4. `tools/function-tool-registry.mo` — Import handlers, add tool definitions with JSON schemas, wire into admin tool set (gated on `resources.filesystem`).
5. `main.mo` — Add `allFilesystemStates : Map<Nat, FilesystemModel.FilesystemState>` to persistent state (keyed by agent ID). On each request, look up the dispatched agent's ID, extract its `FilesystemState` (defaulting to empty if first use), and pass it through the context.
6. `events/types/event-processing-context.mo` — Add `filesystemState : FilesystemModel.FilesystemState` to context (already resolved to the current agent's instance before passing in).
7. `agents/admin/org-admin-agent.mo` — Include `filesystem` in `ToolResources` (the admin agent's own isolated instance).
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (filesystem-model): `put` → `get` round-trip. `put` with non-absolute path → path normalized. `delete` existing → returns entry. `delete` missing → error. `list` with prefix filtering. `list` with `/` returns all. Empty filesystem returns `[]`.
- Unit test (create-file-entry-handler): valid payload → entry created. Duplicate path → error. Missing required fields → error.
- Unit test (update-file-entry-handler): existing path → updated. Non-existent path → error. Partial update (only content, or only description) → other fields preserved.
- Unit test (list-file-entries-handler): entries under `/skills/` listed when prefix is `/skills/`. Content excluded from listing output.
- Unit test (delete-file-entry-handler): existing path → deleted. Non-existent path → error.
- Integration test: admin agent creates, lists, reads, updates, and deletes a file entry through the full Slack → LLM → tool flow.

---

### 5.3 — Store: Agent-Facing Tools (`file_read` / `file_write`)

**Goal**

Expose the Store to non-admin agents via `file_read` and `file_write` tools, so any `#api` agent can read from and write to its own Store entries during LLM tool loops. This enables agents to build persistent knowledge (notes, plans, drafts, skill documents) that survives across turns and sessions. Each agent reads and writes only its own store; there is no cross-agent store access.

**Current State (after 5.2)**

- Store model exists with CRUD operations.
- Admin tools (`create_file_entry`, `update_file_entry`, etc.) are available to the `#admin` agent.
- Non-admin agents (`#planning`, `#research`, `#communication`) have no access to Store.
- `ToolResources.filesystem` exists but is only wired for admin agents.

**Desired State**

- Two new tools available to all `#api` agent categories:
  - `file_read(path)` — Two unambiguous modes determined solely by the path argument:
    - **Path ending in `/`** → directory listing. Returns `[{ path, description }]` for all entries whose path starts with that prefix. Returns an empty array if nothing matches — never an error.
    - **Exact path (no trailing `/`)** → file read. Returns `{ path, name, extension, description, content }`. Returns an error if the path does not exist.
  - `file_write(path, content, description?)` — Creates or updates a file entry. If the path doesn't exist, creates it (auto-derives `name` and `extension` from the path). If it exists, updates content and optionally description. The `description` parameter is required on creation, optional on update.
- Tools gated on `ToolResources.filesystem` (non-null = available; `write = true` enables `file_write`).
- All agent category services (`org-admin-agent.mo`, `work-planning-agent.mo`, and future agents) wire `filesystem` into their `ToolResources` with appropriate access (read-only or read-write based on the agent's category/config). Each service receives only the calling agent's own `FilesystemState` — never another agent's.
- `EventProcessingContext` already carries the dispatched agent's `filesystemState` (wired in 5.2 for admin; extended here to all agent categories).

**Design Notes**

- **`file_read` and `file_write`** are the LLM-facing names (per ARCHITECTURE.md's planned tool list). They are distinct from the admin CRUD tools in 5.2 — admin tools are for explicit management (create/delete/list with full metadata), while `file_read`/`file_write` are for agents to use the filesystem as a working file system during reasoning.
- **`file_read` mode dispatch**: the trailing `/` on the path is the sole dispatch signal — it is never ambiguous. Paths ending in `/` always list; paths without a trailing `/` always read. A missing exact path is always an error; a listing with no matches is always an empty array. This eliminates any silent fallback behavior that would confuse the LLM.
- **Write access control**: all `#api` agents get `file_write` by default (writing to their own store only). A future phase may restrict write access per-agent via `toolsAllowed` or per-path policies.
- **Agent attribution**: `file_write` sets `updatedBy` to the agent's name. `createdBy` is set on first creation.
- **No embedding/search yet**: `file_search` (embedding-based retrieval) is deferred to a future phase. Agents use `file_read` with path prefix for now.

**Source Steps**

1. New files: `tools/handlers/filesystem/file-read-handler.mo`, `tools/handlers/filesystem/file-write-handler.mo`.
2. `tools/function-tool-registry.mo` — Add `file_read` and `file_write` tool definitions with JSON schemas. Gate on `resources.filesystem`. `file_write` additionally gated on `filesystem.write = true`.
3. `agents/planning/work-planning-agent.mo` — Wire `filesystem` into `ToolResources` with `write = true` (the planning agent's own filesystem instance).
4. `agents/admin/org-admin-agent.mo` — Ensure `filesystem` is also wired (already done in 5.2, but confirm `file_read`/`file_write` appear alongside admin tools).
5. `events/types/event-processing-context.mo` — Confirm `filesystemState` (the dispatched agent's isolated instance) is available to all agent categories.
6. `events/agent-router.mo` / `orchestrators/agent-orchestrator.mo` — Ensure `allFilesystemStates` lookup by agent ID happens before dispatch, so every category service receives the correct isolated `FilesystemState`.
7. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (file-read-handler): read existing exact path → returns content. Read non-existent exact path → error. Read with trailing `/` and matching entries → returns listing `[{ path, description }]`. Read with trailing `/` and no matches → returns empty array (no error).
- Unit test (file-write-handler): write to new path → creates entry with correct `name`, `extension`, `createdBy`. Write to existing path → updates content + `updatedBy`. Write without `description` to existing entry → preserves existing description. Write without `description` to new path → error (description required on creation).
- Integration test: planning agent uses `file_write` to save a plan draft → `file_read` (exact path) to retrieve it → content matches. Planning agent uses `file_read("/")` (trailing `/`) → sees listing of all its own files, no entries from other agents.
- Verify admin agent still has both admin Store tools (from 5.2) and `file_read`/`file_write` (from 5.3) in the same tool set, all operating on the admin agent's own isolated store.

---

## Decisions

- **3 focused PRs** covering the top priorities: channel security (5.1), then Store in two phases (5.2 model + admin tools, 5.3 agent-facing tools).
- **GitHub integration deferred**: Runtime type migration, webhook ingress, and Coding Agent dispatch are valuable but not the immediate priority. They'll be planned in a later version.
- **Agent allowlist first** (5.1) because it's the highest-priority security boundary — independent and self-contained.
- **Store split into two PRs** because the full scope (model + admin tools + agent tools + wiring across all categories) is too large for one review. PR 5.2 delivers the foundation and admin management; PR 5.3 delivers the agent-facing tools that make the Store useful in practice.
- **Agent-scoped store, no cross-agent access**: the store is isolated per agent. There is no shared store, no cross-agent reads, and no admin-managed global knowledge base. If agents need to share knowledge, they do so through Slack messages. This enforces explicit, auditable communication.
- **No separate skill model**: skill documents are file entries under `/skills/` paths by convention, not a distinct data type. This keeps the persistence model unified.
- **`file_read`/`file_write` naming** follows ARCHITECTURE.md's planned tool list. They're the agent-facing API; admin CRUD tools use more explicit names (`create_file_entry`, etc.).
- **Minimum 1 channel required**: agents must always have at least one channel in their allowlist. The last channel cannot be removed. Channels can be added/changed, but the allowlist cannot be emptied.
- **Embedding-based search deferred**: `file_search` requires an embedding pipeline which is a separate effort. Agents use `file_read` with path prefixes for discovery in v0.5.
