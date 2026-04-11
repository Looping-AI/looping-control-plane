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

**TL;DR**: Enforce per-agent channel security boundaries, then build the Store — a file-like persistent knowledge layer that agents can read from and write to. The Store is a large feature, so it's split across two PRs: first the data model + admin tools, then the agent-facing `file_read`/`file_write` tools wired into the LLM tool loop. GitHub integration is deferred to a later version.

---

### 5.1 — Agent Channel Allowlist

**Goal**

Add a per-agent Slack channel allowlist (`allowedChannelIds`) to the agent model and enforce it in the `AgentRouter` before dispatching to any category service. When a message references an agent outside its allowed channels, the router blocks execution and posts an automatic warning to Slack. Agents with an empty allowlist are unrestricted (backward-compatible default).

**Current State**

- `AgentRecord` has no `allowedChannelIds` field — agents respond to `::` references in any channel.
- `AgentRouter` checks execution type and category/context match but has no channel guard.
- ARCHITECTURE.md specifies: "The Slack channel must be present in the referenced agent's `allowedChannelIds`. If not, the router posts a warning with the allowed channels and skips execution."

**Desired State**

- `AgentRecord` gains `allowedChannelIds : [Text]` — a list of Slack channel IDs where the agent is permitted to run. Empty list = unrestricted (no breaking change for existing agents).
- `AgentRouter.route()` gains a pre-dispatch guard: if `allowedChannelIds` is non-empty and the message's channel ID is not in the list, it posts an automatic Slack warning listing the allowed channels and skips execution (no category service dispatch).
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

### 5.2 — Store: Data Model + Admin Tools

**Goal**

Introduce the Store — a file-like key-value persistence layer for structured and unstructured agent knowledge, scoped per workspace. This phase builds the data model and wires admin-facing tools so workspace admins can create, read, list, and delete Store entries via the `::workspace-admin` agent. Agent-facing tools (`file_read`, `file_write`) come in 5.3.

**Current State**

- No Store model exists. ARCHITECTURE.md specifies Store as a `[planned]` concept.
- Agents have no persistent knowledge storage beyond session traces and channel history.
- `ToolResources` in `tool-types.mo` has no Store resource.
- Skill documents are planned as a Store subtype under `/skills/` paths but do not exist yet.

**Desired State**

- New `models/store-model.mo` module with the following data types and operations:

  ```motoko
  public type StoreEntry = {
    path : Text; // absolute path, e.g. "/skills/create-spec/SKILL.md"
    name : Text; // filename, e.g. "SKILL.md"
    extension : Text; // e.g. "md", "json", "txt"
    description : Text; // LLM guidance: purpose, update cadence, interaction rules
    content : Text; // the file content
    workspaceId : Nat; // owning workspace
    createdAt : Int; // timestamp (nanoseconds)
    updatedAt : Int; // timestamp (nanoseconds)
    createdBy : Text; // Slack user ID or agent name
    updatedBy : Text; // Slack user ID or agent name
  };

  ```

- Store state: `StoreState = Map<Text, StoreEntry>` keyed by `path`. All paths must start with `/`. The model normalizes non-absolute paths automatically (prepends `/`).
- Model functions (state parameter first, per Motoko conventions):
  - `put(state, entry) → Result<StoreEntry, Text>` — creates or updates an entry. Validates path format.
  - `get(state, path) → ?StoreEntry` — retrieves a single entry by exact path.
  - `delete(state, path) → Result<StoreEntry, Text>` — removes an entry, returns the deleted entry.
  - `list(state, pathPrefix) → [StoreEntry]` — lists all entries whose path starts with `pathPrefix`. If prefix is `/`, returns all entries in the store. If prefix is `/skills/`, returns only skill documents.
  - `listPaths(state, pathPrefix) → [Text]` — lightweight variant returning only paths (for directory-like browsing).
- New `ToolResources` field:

  ```motoko
  store : ?{
    state : StoreModel.StoreState;
    workspaceId : Nat;
    write : Bool;
  };

  ```

- New admin tool handlers in `tools/handlers/store/`:
  - `create-store-entry-handler.mo` — Creates a new Store entry. Fails if path already exists (use `update` for overwrites).
  - `update-store-entry-handler.mo` — Updates content and/or description of an existing entry. Fails if path doesn't exist.
  - `get-store-entry-handler.mo` — Reads a single entry by path.
  - `list-store-entries-handler.mo` — Lists entries by path prefix. Returns path, name, extension, description (no content — too large for listing).
  - `delete-store-entry-handler.mo` — Deletes an entry by path.
- Tools wired into `org-admin-agent.mo` via `FunctionToolRegistry` (admin category, write access).
- Persistent state: `storeState` added to `main.mo` as a `StoreModel.StoreState`, passed through `EventProcessingContext` → `AdminAgentCtx`.

**Design Notes**

- **Workspace-scoped**: each Store entry belongs to a workspace. Admin tools operate on the current workspace. Cross-workspace access is not supported (agents access only their workspace's store).
- **Path uniqueness**: paths are globally unique within a workspace. `put` overwrites on same path; `create` rejects duplicates.
- **No content-size limit enforced in v0.5**: the IC's stable memory limits apply naturally. A future task may add explicit limits.
- **Skills are just Store entries**: no separate skill model. Skill-specific conventions (e.g., `/skills/<id>/SKILL.md`) are enforced by convention in tool descriptions, not by the model.

**Source Steps**

1. New file: `models/store-model.mo` — `StoreEntry` type, `StoreState` type alias, `put`, `get`, `delete`, `list`, `listPaths`, path normalization utility.
2. `tool-types.mo` — Add `store` field to `ToolResources`.
3. New files: `tools/handlers/store/create-store-entry-handler.mo`, `update-store-entry-handler.mo`, `get-store-entry-handler.mo`, `list-store-entries-handler.mo`, `delete-store-entry-handler.mo`.
4. `tools/function-tool-registry.mo` — Import handlers, add tool definitions with JSON schemas, wire into admin tool set (gated on `resources.store`).
5. `main.mo` — Add `storeState : StoreModel.StoreState` to persistent state. Pass through event processing context.
6. `events/types/event-processing-context.mo` — Add `storeState` to context.
7. `agents/admin/org-admin-agent.mo` — Include `store` in `ToolResources` when building admin agent context.
8. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (store-model): `put` → `get` round-trip. `put` with non-absolute path → path normalized. `delete` existing → returns entry. `delete` missing → error. `list` with prefix filtering. `list` with `/` returns all. Empty store returns `[]`.
- Unit test (create-store-entry-handler): valid payload → entry created. Duplicate path → error. Missing required fields → error.
- Unit test (update-store-entry-handler): existing path → updated. Non-existent path → error. Partial update (only content, or only description) → other fields preserved.
- Unit test (list-store-entries-handler): entries under `/skills/` listed when prefix is `/skills/`. Content excluded from listing output.
- Unit test (delete-store-entry-handler): existing path → deleted. Non-existent path → error.
- Integration test: admin agent creates, lists, reads, updates, and deletes a Store entry through the full Slack → LLM → tool flow.

---

### 5.3 — Store: Agent-Facing Tools (`file_read` / `file_write`)

**Goal**

Expose the Store to non-admin agents via `file_read` and `file_write` tools, so any `#api` agent can read from and write to Store entries within its workspace during LLM tool loops. This enables agents to build persistent knowledge (notes, plans, drafts, skill documents) that survives across turns and sessions.

**Current State (after 5.2)**

- Store model exists with CRUD operations.
- Admin tools (`create_store_entry`, `update_store_entry`, etc.) are available to the `#admin` agent.
- Non-admin agents (`#planning`, `#research`, `#communication`) have no access to Store.
- `ToolResources.store` exists but is only wired for admin agents.

**Desired State**

- Two new tools available to all `#api` agent categories:
  - `file_read(path)` — Reads a Store entry's content by path. Returns `{ path, name, extension, description, content }`. Returns an error if path doesn't exist. Can also accept a `pathPrefix` parameter to list available files (returns paths + descriptions, no content) — combining read and directory listing in one tool to minimize tool count.
  - `file_write(path, content, description?)` — Creates or updates a Store entry. If the path doesn't exist, creates it (auto-derives `name` and `extension` from the path). If it exists, updates content and optionally description. The `description` parameter is required on creation, optional on update.
- Tools gated on `ToolResources.store` (non-null = available; `write = true` enables `file_write`).
- All agent category services (`org-admin-agent.mo`, `work-planning-agent.mo`, and future agents) wire `store` into their `ToolResources` with appropriate access (read-only or read-write based on the agent's category/config).
- `EventProcessingContext` passes `storeState` to all agent category services (already done in 5.2 for admin; extended here to planning and others).

**Design Notes**

- **`file_read` and `file_write`** are the LLM-facing names (per ARCHITECTURE.md's planned tool list). They are distinct from the admin CRUD tools in 5.2 — admin tools are for explicit management (create/delete/list with full metadata), while `file_read`/`file_write` are for agents to use Store as a working file system during reasoning.
- **`file_read` with prefix listing**: when called with a path that ends in `/` or doesn't match an exact entry, the tool returns a directory listing instead. This avoids needing a separate `file_list` tool.
- **Write access control**: all `#api` agents get `file_write` by default. A future phase may restrict write access per-agent via `toolsAllowed` or per-path policies.
- **Agent attribution**: `file_write` sets `updatedBy` to the agent's name. `createdBy` is set on first creation.
- **No embedding/search yet**: `store_search` (embedding-based retrieval) is deferred to a future phase. Agents use `file_read` with path prefix for now.

**Source Steps**

1. New files: `tools/handlers/store/file-read-handler.mo`, `tools/handlers/store/file-write-handler.mo`.
2. `tools/function-tool-registry.mo` — Add `file_read` and `file_write` tool definitions with JSON schemas. Gate on `resources.store`. `file_write` additionally gated on `store.write = true`.
3. `agents/planning/work-planning-agent.mo` — Wire `store` into `ToolResources` with `write = true`.
4. `agents/admin/org-admin-agent.mo` — Ensure `store` is also wired (already done in 5.2, but confirm `file_read`/`file_write` appear alongside admin tools).
5. `events/types/event-processing-context.mo` — Confirm `storeState` is available to all agent categories.
6. `events/agent-router.mo` / `orchestrators/agent-orchestrator.mo` — Pass `store` resource through to non-admin agent categories (extend `PlanningAgentCtx` or equivalent to include `storeState`).
7. Verify: `icp build control-plane-core`, `mops test`, `bun run tsc --noEmit`.

**Test Steps**

- Unit test (file-read-handler): read existing path → returns content. Read non-existent path → error. Read with path prefix (ending `/`) → returns directory listing with paths + descriptions.
- Unit test (file-write-handler): write to new path → creates entry with correct `name`, `extension`, `createdBy`. Write to existing path → updates content + `updatedBy`. Write without `description` to existing entry → preserves existing description. Write without `description` to new path → error (description required on creation).
- Integration test: planning agent uses `file_write` to save a plan draft → `file_read` to retrieve it → content matches. Planning agent uses `file_read` with `/` prefix → sees all workspace files.
- Verify admin agent still has both admin Store tools (from 5.2) and `file_read`/`file_write` (from 5.3) in the same tool set.

---

## Decisions

- **3 focused PRs** covering the top priorities: channel security (5.1), then Store in two phases (5.2 model + admin tools, 5.3 agent-facing tools).
- **GitHub integration deferred**: Runtime type migration, webhook ingress, and Coding Agent dispatch are valuable but not the immediate priority. They'll be planned in a later version.
- **Agent allowlist first** (5.1) because it's the highest-priority security boundary — independent and self-contained.
- **Store split into two PRs** because the full scope (model + admin tools + agent tools + wiring across all categories) is too large for one review. PR 5.2 delivers the foundation and admin management; PR 5.3 delivers the agent-facing tools that make the Store useful in practice.
- **No separate skill model**: skill documents are Store entries under `/skills/` paths by convention, not a distinct data type. This keeps the persistence model unified.
- **`file_read`/`file_write` naming** follows ARCHITECTURE.md's planned tool list. They're the agent-facing API; admin CRUD tools use more explicit names (`create_store_entry`, etc.).
- **Empty allowlist = unrestricted**: backward-compatible default so existing agents and tests don't break.
- **Embedding-based search deferred**: `store_search` requires an embedding pipeline which is a separate effort. Agents use `file_read` with path prefixes for discovery in v0.5.
