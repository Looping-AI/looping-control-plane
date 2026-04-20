import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Types "../types";

module {
  // ============================================
  // Types
  // ============================================

  /// The sub-kind for system-managed agents.
  public type SystemAgentKind = {
    #admin; // org administration: workspace & channel management
    #onboarding; // handles direct messages to the Slack App — stub, planned
  };

  /// The execution engines an agent is allowed to use.
  /// Stored as an array on AgentConfig so an agent can support multiple modes.
  ///   #canister — external canister called via envelope/package webhook
  ///   #github   — GitHub Actions workflow triggered via webhook; reply delivered back signed
  public type ExecutionEngine = {
    #canister;
    #github;
  };

  /// The broad category an agent belongs to.
  /// Categories drive which tool set is available and skills the LLM is prompted with.
  ///   #_system — built-in managed agent (admin, onboarding); only created by the system.
  ///   #custom — user-defined agent registered via the register_agent tool.
  public type AgentCategory = {
    #_system : SystemAgentKind;
    #custom;
  };

  /// Per-tool runtime state: how many times the tool has been invoked and
  /// any accumulated operational knowledge the agent has built up about it.
  public type ToolState = {
    usageCount : Nat;
    knowHow : Text;
  };

  /// Secret access configuration for an agent.
  ///   allowed   — explicit whitelist of (workspaceId, SecretId) pairs this agent may access.
  ///   overrides — per-agent credential overrides: [(targetSecretId, customKeyName)].
  ///               When resolving `targetSecretId`, the model first looks up
  ///               `#custom(customKeyName)` from this agent's workspace before
  ///               falling back to the standard ID and the org-level fallback.
  public type AgentSecretsConfig = {
    allowed : [(Nat, Types.SecretId)];
    overrides : [(Types.SecretId, Text)];
  };

  /// Static configuration for an agent.
  ///   name              — kebab-case identifier, must be unique and match the `::name` syntax.
  ///   model             — OpenRouter model string used for LLM calls (e.g. "openai/gpt-oss-120b").
  ///   executionEngines  — list of engines this agent is permitted to use (non-empty).
  ///   allowedChannelIds — set of Slack channel IDs where non-admin agents may run.
  ///                       Must be non-empty for non-admin agents; cannot be emptied after registration.
  ///                       For #_system(#admin) agents this set is always empty; routing is governed by
  ///                       WorkspaceModel.adminChannelId (single source of truth).
  ///   secrets           — secret access configuration.
  public type AgentConfig = {
    name : Text;
    model : Text;
    executionEngines : [ExecutionEngine];
    allowedChannelIds : Set.Set<Text>;
    secrets : AgentSecretsConfig;
  };

  /// Mutable runtime state for an agent.
  ///   toolsState — per-tool runtime state (usageCount + knowHow text).
  public type AgentState = {
    toolsState : Map.Map<Text, ToolState>;
  };

  /// A registered agent and all configuration required to execute it.
  ///
  /// Fields:
  ///   id       — stable unique identifier (assigned by the registry).
  ///   ownedBy  — the workspace that owns this agent. Immutable after creation.
  ///              Agents owned by workspace 0 are org-wide (e.g. workspace-admin).
  ///   category — determines the available tool catalogue and prompt strategy.
  ///              #_system(#admin) and #_system(#onboarding) are managed by the system.
  ///              #custom is user-defined, registered via register_agent tool.
  ///   config   — static agent configuration (name, model, executionEngines, channels, secrets).
  ///   state    — mutable runtime state (tool usage counters and knowHow).
  public type AgentRecord = {
    id : Nat;
    ownedBy : Nat;
    category : AgentCategory;
    config : AgentConfig;
    state : AgentState;
  };

  /// Type alias for the agent registry state.
  /// Tracks the next agent ID and maintains two indexes:
  ///   - agentsById: O(1) lookup by agent ID
  ///   - agentsByName: O(1) lookup by agent name (case-insensitive)
  public type AgentRegistryState = {
    var nextId : Nat;
    agentsById : Map.Map<Nat, AgentRecord>;
    agentsByName : Map.Map<Text, Nat>; // name → ID lookup
  };

  // ============================================
  // Constructor helpers
  // ============================================

  /// Create an empty agent registry state.
  public func emptyState() : AgentRegistryState {
    {
      var nextId = 0;
      agentsById = Map.empty<Nat, AgentRecord>();
      agentsByName = Map.empty<Text, Nat>();
    };
  };

  /// Build a fresh ToolState with zero usage and no knowHow.
  public func newToolState() : ToolState {
    { usageCount = 0; knowHow = "" };
  };

  // ============================================
  // Helpers
  // ============================================

  /// Validate and normalize an agent name.
  /// Returns `#err` if validation fails, `#ok(normalized_name)` on success.
  private func validateAndNormalizeName(name : Text) : Result.Result<Text, Text> {
    if (name == "") {
      return #err("Agent name cannot be empty.");
    };

    let normalized = Text.toLower(name);

    // Validate: only a-z, 0-9, and hyphens; must not start with a digit
    var firstChar = true;
    for (c in Text.toIter(normalized)) {
      if (firstChar) {
        firstChar := false;
        if (not ((c >= 'a' and c <= 'z'))) {
          return #err("Agent name must start with a lowercase letter.");
        };
      } else {
        if (not ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) {
          return #err("Agent name may only contain lowercase letters, digits, and hyphens.");
        };
      };
    };

    #ok(normalized);
  };

  /// Check if a name is available (not taken by another agent).
  /// If currentAgentId is provided, allows the same agent to keep its own name.
  private func isNameAvailable(
    state : AgentRegistryState,
    normalized : Text,
    currentAgentId : ?Nat,
  ) : Result.Result<(), Text> {
    switch (Map.get(state.agentsByName, Text.compare, normalized)) {
      case (null) {
        // Name is available
        #ok(());
      };
      case (?existingId) {
        // Name is taken, check if it's the same agent
        switch (currentAgentId) {
          case (null) {
            // No agent ID provided, so any existing name is a conflict
            #err("An agent named \"" # normalized # "\" is already registered.");
          };
          case (?agentId) {
            if (existingId == agentId) {
              // Same agent retaining its own name
              #ok(());
            } else {
              // Different agent with this name
              #err("An agent named \"" # normalized # "\" is already registered.");
            };
          };
        };
      };
    };
  };

  // ============================================
  // CRUD operations
  // ============================================

  /// Register a new agent.
  ///
  /// Returns `#err` if:
  ///   - name is empty
  ///   - name contains invalid characters (must be lowercase letters, digits, or hyphens)
  ///   - an agent with that name already exists
  ///
  /// Returns `#ok(id)` with the assigned agent ID on success.
  /// The name is lower-cased before storage so that lookups are case-insensitive.
  public func register(
    state : AgentRegistryState,
    ownedBy : Nat,
    category : AgentCategory,
    config : AgentConfig,
  ) : Result.Result<Nat, Text> {
    let normalized = switch (validateAndNormalizeName(config.name)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(n)) { n };
    };

    switch (isNameAvailable(state, normalized, null)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(())) {};
    };

    // Validate that executionEngines is non-empty.
    if (config.executionEngines.size() == 0) {
      return #err("executionEngines must contain at least one engine.");
    };

    // For #_system(#admin) agents, allowedChannelIds is always empty — routing is governed by
    // WorkspaceModel.adminChannelId. Silently coerce any provided value to empty set.
    // For all other categories, enforce non-empty.
    let effectiveAllowedChannelIds : Set.Set<Text> = switch (category) {
      case (#_system(#admin)) { Set.empty<Text>() };
      case (_) {
        if (Set.size(config.allowedChannelIds) == 0) {
          return #err("allowedChannelIds must contain at least one channel ID.");
        };
        config.allowedChannelIds;
      };
    };

    // Enforce at most one #_system(#admin) agent per workspace.
    if (category == #_system(#admin)) {
      switch (lookupAdminAgentByWorkspace(state, ownedBy)) {
        case (?existing) {
          return #err(
            "Workspace " # Nat.toText(ownedBy) # " already has an admin agent ('" # existing.config.name # "'). " #
            "Only one #_system(#admin) agent is allowed per workspace."
          );
        };
        case (null) {};
      };
    };

    let id = state.nextId;
    let record : AgentRecord = {
      id;
      ownedBy;
      category;
      config = {
        name = normalized;
        model = config.model;
        executionEngines = config.executionEngines;
        allowedChannelIds = effectiveAllowedChannelIds;
        secrets = config.secrets;
      };
      state = {
        toolsState = Map.empty<Text, ToolState>();
      };
    };
    Map.add(state.agentsById, Nat.compare, id, record);
    Map.add(state.agentsByName, Text.compare, normalized, id);
    state.nextId += 1;
    #ok(id);
  };

  /// Look up an agent by ID.
  public func lookupById(state : AgentRegistryState, id : Nat) : ?AgentRecord {
    Map.get(state.agentsById, Nat.compare, id);
  };

  /// Look up an agent by name (case-insensitive).
  public func lookupByName(state : AgentRegistryState, name : Text) : ?AgentRecord {
    let normalized = Text.toLower(name);
    switch (Map.get(state.agentsByName, Text.compare, normalized)) {
      case (null) { null };
      case (?id) { Map.get(state.agentsById, Nat.compare, id) };
    };
  };

  /// Update mutable fields of an existing agent by ID.
  ///
  /// Pass `null` for any field that should remain unchanged.
  /// When updating the name, validates it follows the same rules as registration
  /// and ensures no other agent has the same name (case-insensitive).
  /// Returns `#err` if the agent is not found or validation fails.
  public func updateById(
    state : AgentRegistryState,
    id : Nat,
    newName : ?Text,
    newModel : ?Text,
    newExecutionEngines : ?[ExecutionEngine],
    newSecretsAllowed : ?[(Nat, Types.SecretId)],
    newSecretOverrides : ?[(Types.SecretId, Text)],
    newAllowedChannelIds : ?Set.Set<Text>,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, id)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(id) # " not found.");
      };
      case (?existing) {
        // Validate newExecutionEngines if provided — must be non-empty.
        switch (newExecutionEngines) {
          case (?engines) {
            if (engines.size() == 0) {
              return #err("executionEngines must contain at least one engine.");
            };
          };
          case (null) {};
        };

        // Validate newAllowedChannelIds if provided.
        // For #_system(#admin) agents, always keep the set empty regardless of what is passed —
        // routing is governed by WorkspaceModel.adminChannelId.
        // For non-system agents, reject any attempt to empty the allowlist.
        switch (existing.category) {
          case (#_system(#admin)) {}; // ignored — enforced below in record construction
          case (_) {
            switch (newAllowedChannelIds) {
              case (?s) {
                if (Set.size(s) == 0) {
                  return #err("allowedChannelIds must contain at least one channel ID; the allowlist cannot be emptied.");
                };
              };
              case (null) {};
            };
          };
        };

        // If newName is provided, validate it
        let finalName = switch (newName) {
          case (null) { existing.config.name };
          case (?name) {
            let normalized = switch (validateAndNormalizeName(name)) {
              case (#err(msg)) { return #err(msg) };
              case (#ok(n)) { n };
            };

            switch (isNameAvailable(state, normalized, ?id)) {
              case (#err(msg)) { return #err(msg) };
              case (#ok(())) {};
            };

            normalized;
          };
        };

        let updated : AgentRecord = {
          id = existing.id;
          ownedBy = existing.ownedBy; // immutable — ownership cannot be transferred
          category = existing.category; // immutable — category cannot be changed after creation
          config = {
            name = finalName;
            model = switch (newModel) {
              case (null) { existing.config.model };
              case (?m) { m };
            };
            executionEngines = switch (newExecutionEngines) {
              case (null) { existing.config.executionEngines };
              case (?e) { e };
            };
            secrets = {
              allowed = switch (newSecretsAllowed) {
                case (null) { existing.config.secrets.allowed };
                case (?s) { s };
              };
              overrides = switch (newSecretOverrides) {
                case (null) { existing.config.secrets.overrides };
                case (?o) { o };
              };
            };
            allowedChannelIds = switch (existing.category) {
              case (#_system(#admin)) { Set.empty<Text>() }; // always empty — router uses WorkspaceModel.adminChannelId
              case (_) {
                switch (newAllowedChannelIds) {
                  case (null) { existing.config.allowedChannelIds };
                  case (?s) { s };
                };
              };
            };
          };
          state = existing.state; // runtime state is not updated via this function
        };

        // Update the agent record
        Map.add(state.agentsById, Nat.compare, id, updated);

        // If name changed, update the name index
        if (finalName != existing.config.name) {
          Map.remove(state.agentsByName, Text.compare, existing.config.name);
          Map.add(state.agentsByName, Text.compare, finalName, id);
        };

        #ok(true);
      };
    };
  };

  /// Update the toolsState entry for a single tool within an existing agent.
  ///
  /// Useful for incrementing usageCount or persisting accumulated knowHow
  /// without rewriting the entire AgentRecord.
  /// Returns `#err` if the agent is not found.
  public func updateToolState(
    state : AgentRegistryState,
    agentId : Nat,
    toolName : Text,
    toolState : ToolState,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, agentId)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(agentId) # " not found.");
      };
      case (?existing) {
        Map.add(existing.state.toolsState, Text.compare, toolName, toolState);
        #ok(true);
      };
    };
  };

  /// Unregister an agent by ID.
  /// Returns `#err` if the agent is not found.
  public func unregisterById(state : AgentRegistryState, id : Nat) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, id)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(id) # " not found.");
      };
      case (?record) {
        Map.remove(state.agentsById, Nat.compare, id);
        Map.remove(state.agentsByName, Text.compare, record.config.name);
        #ok(true);
      };
    };
  };

  /// Return all registered agents as an array.
  public func listAgents(state : AgentRegistryState) : [AgentRecord] {
    Iter.toArray(Map.values(state.agentsById));
  };

  /// Return the first registered agent with the given category, or null if none found.
  /// Iteration order follows insertion order of the underlying map.
  public func getFirstByCategory(state : AgentRegistryState, category : AgentCategory) : ?AgentRecord {
    for (record in Map.values(state.agentsById)) {
      if (record.category == category) {
        return ?record;
      };
    };
    null;
  };

  /// Return the first registered #_system(#admin) agent for the given workspaceId, or null if none found.
  public func lookupAdminAgentByWorkspace(state : AgentRegistryState, workspaceId : Nat) : ?AgentRecord {
    for (record in Map.values(state.agentsById)) {
      if (record.category == #_system(#admin) and record.ownedBy == workspaceId) {
        return ?record;
      };
    };
    null;
  };

  /// Returns true if the agent is the org-level admin:
  /// category #_system(#admin) AND owned by workspace 0.
  public func isOrgAdmin(agent : AgentRecord) : Bool {
    agent.category == #_system(#admin) and agent.ownedBy == 0;
  };

  /// Count all registered agents with the given category.
  public func countByCategory(state : AgentRegistryState, category : AgentCategory) : Nat {
    var count = 0;
    for (record in Map.values(state.agentsById)) {
      if (record.category == category) {
        count += 1;
      };
    };
    count;
  };

  /// Create the default agent registry state pre-seeded with the built-in
  /// workspace-admin agent (category = #admin, OpenRouter openai/gpt-oss-120b).
  ///
  /// The default admin agent is granted access to the org-level (workspace 0)
  /// OpenRouter API key and Slack bot token, required for critical administrative tasks.
  ///
  /// Called once during canister initialization in main.mo.
  public func defaultState() : AgentRegistryState {
    let state = emptyState();
    ignore register(
      state,
      0, // owned by workspace 0 — org-wide agent
      #_system(#admin),
      {
        name = "workspace-admin";
        model = "openai/gpt-oss-120b";
        executionEngines = [#canister];
        allowedChannelIds = Set.empty<Text>(); // #_system(#admin) agents never use allowedChannelIds
        secrets = {
          allowed = [(0, #openRouterApiKey)];
          overrides = []; // no overrides for the built-in admin agent
        };
      },
    );
    state;
  };

  /// Return true if the agent has a secrets.allowed entry for (workspaceId, secretId).
  public func isSecretAllowed(agent : AgentRecord, workspaceId : Nat, secretId : Types.SecretId) : Bool {
    for ((wsId, sId) in agent.config.secrets.allowed.vals()) {
      if (wsId == workspaceId and sId == secretId) {
        return true;
      };
    };
    false;
  };

  // ============================================
  // Shareable view (crossing the shared boundary)
  // ============================================

  /// Serializable view of AgentSecretsConfig (arrays; no conversion needed).
  public type AgentSecretsConfigView = {
    allowed : [(Nat, Types.SecretId)];
    overrides : [(Types.SecretId, Text)];
  };

  /// Serializable view of AgentConfig: Set<Text> flattened to [Text].
  public type AgentConfigView = {
    name : Text;
    model : Text;
    executionEngines : [ExecutionEngine];
    allowedChannelIds : [Text];
    secrets : AgentSecretsConfigView;
  };

  /// Serializable view of AgentState: Map<Text,ToolState> flattened to array.
  public type AgentStateView = {
    toolsState : [(Text, ToolState)];
  };

  /// A serializable snapshot of an AgentRecord suitable for returning from
  /// shared (public) canister methods.  The mutable Map inside toolsState
  /// and the Set inside allowedChannelIds are flattened to arrays.
  public type AgentRecordView = {
    id : Nat;
    ownedBy : Nat;
    category : AgentCategory;
    config : AgentConfigView;
    state : AgentStateView;
  };

  /// Convert an AgentRecord to a shareable AgentRecordView.
  public func toView(record : AgentRecord) : AgentRecordView {
    {
      id = record.id;
      ownedBy = record.ownedBy;
      category = record.category;
      config = {
        name = record.config.name;
        model = record.config.model;
        executionEngines = record.config.executionEngines;
        allowedChannelIds = Set.toArray(record.config.allowedChannelIds);
        secrets = {
          allowed = record.config.secrets.allowed;
          overrides = record.config.secrets.overrides;
        };
      };
      state = {
        toolsState = Iter.toArray(Map.entries(record.state.toolsState));
      };
    };
  };
};
