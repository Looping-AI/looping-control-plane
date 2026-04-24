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

## Plan: v0.5 — Filesystem

**TL;DR**: Build the Filesystem — a file-like persistent knowledge layer that each agent owns exclusively and can read from and write to — in two focused PRs: first the data model + admin tools (5.3), then the agent-facing `file_read`/`file_write` tools (5.4). GitHub integration remains deferred to a later version.

---

### 5.2.1 — HMAC encrypted envelop (JSON format always)

- on core, generate a private key for the engine and submit it through an inter canister call.
- on engine, store the secret and ensure request is coming from the owner.
- when envelope is generated, it converts to JSON, and then is encrypted in HMAC and sent on the execute call (both the signature and the body).
- Engine decripts the body, then parses it to Candid, then proceeds as usual.

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

- **Filesystem split into two PRs** because the full scope (model + admin tools + agent tools + wiring across all categories) is too large for one review. PR 5.3 delivers the foundation and admin management; PR 5.4 delivers the agent-facing tools that make the Filesystem useful in practice.
- **Agent-scoped filesystem, no cross-agent access**: each agent's filesystem is fully isolated. There is no shared filesystem, no cross-agent reads, and no admin-managed global knowledge base. If agents need to share knowledge, they do so through Slack messages. This enforces explicit, auditable communication.
- **No separate skill model**: skill documents are file entries under `/skills/` paths by convention, not a distinct data type. This keeps the persistence model unified.
- **`file_read`/`file_write` naming** follows ARCHITECTURE.md's planned tool list. They're the agent-facing API; admin CRUD tools use more explicit names (`create_file_entry`, etc.).
- **Embedding-based search deferred**: `file_search` requires an embedding pipeline which is a separate effort. Agents use `file_read` with path prefixes for discovery in v0.5.
