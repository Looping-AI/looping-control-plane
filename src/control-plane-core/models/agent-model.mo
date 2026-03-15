import Map "mo:core/Map";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Types "../types";

module {
  // ============================================
  // Types
  // ============================================

  /// The broad category an agent belongs to.
  /// Categories drive which tool set is available and skills the LLM is prompted with.
  public type AgentCategory = {
    #admin; // org administration: workspace & channel management
    #planning; // work planning: value streams, metrics, objectives
    #research; // information gathering — stub, Phase 5
    #communication; // drafting, summarizing, messaging — stub, Phase 5
  };

  /// OpenRouter-specific model variants.
  public type OpenRouterModel = {
    #gpt_oss_120b; // OpenRouter: gpt-oss-120b
  };

  /// LLM provider + model pairing.
  /// Each provider has its own set of supported models.
  public type LlmModel = {
    #openRouter : OpenRouterModel;
  };

  /// The execution type of an agent — determines whether work is done inside the
  /// canister or delegated to a remote runtime.
  public type AgentExecutionType = {
    #api; // In-canister LLM loop; calls OpenRouter directly
    #runtime : RuntimeAgentConfig; // Delegated to a remote runtime environment
  };

  /// Configuration for an agent that runs in a remote runtime.
  /// Combines a hosting choice (where the runtime runs) with a framework
  /// choice (which agent framework drives execution).
  public type RuntimeAgentConfig = {
    hosting : HostingConfig;
    framework : AgentFrameworkConfig;
  };

  /// Where the runtime environment is hosted.
  /// Only #codespace is supported in v0.3; the workspace's linked codespace
  /// (from codespace-model.mo) is resolved via the agent's workspaceId.
  public type HostingConfig = {
    #codespace; // extensible: future hosting solutions added here
  };

  /// Which agent framework drives execution inside the runtime.
  /// deployedVersion is null until the sidecar health check runs at deploy time
  /// (Phase C.1). Pinned after that until an explicit admin upgrade.
  public type AgentFrameworkConfig = {
    #openClaw : { deployedVersion : ?Text }; // extensible: future frameworks added here
  };

  /// Per-tool runtime state: how many times the tool has been invoked and
  /// any accumulated operational knowledge the agent has built up about it.
  public type ToolState = {
    usageCount : Nat;
    knowHow : Text;
  };

  /// A registered agent and all configuration required to execute it.
  ///
  /// Fields:
  ///   id              — stable unique identifier (assigned by the registry).
  ///   name            — kebab-case identifier, must be unique and match the `::name` syntax.
  ///   workspaceId     — the workspace that owns this agent. Immutable after creation.
  ///                     Agents owned by workspace 0 are org-wide (e.g. workspace-admin).
  ///   category        — determines the available tool catalogue and prompt strategy.
  ///   llmModel        — provider and model variant (e.g. #openRouter(#gpt_oss_120b)).
  ///   executionType   — #api runs in-canister; #runtime delegates to a remote environment.
  ///   secretsAllowed  — explicit whitelist of (workspaceId, SecretId) pairs this agent may access.
  ///   secretOverrides — per-agent credential overrides: [(targetSecretId, customKeyName)].
  ///                     When resolving `targetSecretId`, the model first looks up
  ///                     `#custom(customKeyName)` from this agent's workspace before
  ///                     falling back to the standard ID and the org-level fallback.
  ///   toolsDisallowed — blocklist of tool names to exclude from LLM tool set (by function name).
  ///   toolsMisconfigured — tools excluded due to operator errors; cleared after investigation.
  ///   toolsState      — per-tool runtime state (usageCount + knowHow text).
  ///   sources         — knowledge-source identifiers (URLs, doc refs, etc.) available to the agent.
  public type AgentRecord = {
    id : Nat;
    name : Text;
    workspaceId : Nat;
    category : AgentCategory;
    llmModel : LlmModel;
    executionType : AgentExecutionType;
    secretsAllowed : [(Nat, Types.SecretId)];
    secretOverrides : [(Types.SecretId, Text)];
    toolsDisallowed : [Text];
    toolsMisconfigured : [Text];
    toolsState : Map.Map<Text, ToolState>;
    sources : [Text];
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
    normalized : Text,
    state : AgentRegistryState,
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
    name : Text,
    workspaceId : Nat,
    category : AgentCategory,
    llmModel : LlmModel,
    executionType : AgentExecutionType,
    secretsAllowed : [(Nat, Types.SecretId)],
    secretOverrides : [(Types.SecretId, Text)],
    toolsDisallowed : [Text],
    toolsMisconfigured : [Text],
    toolsState : Map.Map<Text, ToolState>,
    sources : [Text],
    state : AgentRegistryState,
  ) : Result.Result<Nat, Text> {
    let normalized = switch (validateAndNormalizeName(name)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(n)) { n };
    };

    switch (isNameAvailable(normalized, state, null)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(())) {};
    };

    let id = state.nextId;
    let record : AgentRecord = {
      id;
      name = normalized;
      workspaceId;
      category;
      llmModel;
      executionType;
      secretsAllowed;
      secretOverrides;
      toolsDisallowed;
      toolsMisconfigured;
      toolsState;
      sources;
    };
    Map.add(state.agentsById, Nat.compare, id, record);
    Map.add(state.agentsByName, Text.compare, normalized, id);
    state.nextId += 1;
    #ok(id);
  };

  /// Look up an agent by ID.
  public func lookupById(id : Nat, state : AgentRegistryState) : ?AgentRecord {
    Map.get(state.agentsById, Nat.compare, id);
  };

  /// Look up an agent by name (case-insensitive).
  public func lookupByName(name : Text, state : AgentRegistryState) : ?AgentRecord {
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
    id : Nat,
    newName : ?Text,
    newCategory : ?AgentCategory,
    newLlmModel : ?LlmModel,
    newExecutionType : ?AgentExecutionType,
    newSecretsAllowed : ?[(Nat, Types.SecretId)],
    newSecretOverrides : ?[(Types.SecretId, Text)],
    newToolsDisallowed : ?[Text],
    newToolsMisconfigured : ?[Text],
    newToolsState : ?Map.Map<Text, ToolState>,
    newSources : ?[Text],
    state : AgentRegistryState,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, id)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(id) # " not found.");
      };
      case (?existing) {
        // If newName is provided, validate it
        let finalName = switch (newName) {
          case (null) { existing.name };
          case (?name) {
            let normalized = switch (validateAndNormalizeName(name)) {
              case (#err(msg)) { return #err(msg) };
              case (#ok(n)) { n };
            };

            switch (isNameAvailable(normalized, state, ?id)) {
              case (#err(msg)) { return #err(msg) };
              case (#ok(())) {};
            };

            normalized;
          };
        };

        let updated : AgentRecord = {
          id = existing.id;
          name = finalName;
          workspaceId = existing.workspaceId; // immutable — ownership cannot be transferred
          category = switch (newCategory) {
            case (null) { existing.category };
            case (?c) { c };
          };
          llmModel = switch (newLlmModel) {
            case (null) { existing.llmModel };
            case (?m) { m };
          };
          executionType = switch (newExecutionType) {
            case (null) { existing.executionType };
            case (?et) { et };
          };
          secretsAllowed = switch (newSecretsAllowed) {
            case (null) { existing.secretsAllowed };
            case (?s) { s };
          };
          secretOverrides = switch (newSecretOverrides) {
            case (null) { existing.secretOverrides };
            case (?o) { o };
          };
          toolsDisallowed = switch (newToolsDisallowed) {
            case (null) { existing.toolsDisallowed };
            case (?t) { t };
          };
          toolsMisconfigured = switch (newToolsMisconfigured) {
            case (null) { existing.toolsMisconfigured };
            case (?t) { t };
          };
          toolsState = switch (newToolsState) {
            case (null) { existing.toolsState };
            case (?s) { s };
          };
          sources = switch (newSources) {
            case (null) { existing.sources };
            case (?src) { src };
          };
        };

        // Update the agent record
        Map.add(state.agentsById, Nat.compare, id, updated);

        // If name changed, update the name index
        if (finalName != existing.name) {
          Map.remove(state.agentsByName, Text.compare, existing.name);
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
    agentId : Nat,
    toolName : Text,
    toolState : ToolState,
    state : AgentRegistryState,
  ) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, agentId)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(agentId) # " not found.");
      };
      case (?existing) {
        Map.add(existing.toolsState, Text.compare, toolName, toolState);
        #ok(true);
      };
    };
  };

  /// Fork an existing agent into a new workspace.
  ///
  /// Creates a new agent record inheriting the strategic configuration of the
  /// original (category, llmModel, toolsDisallowed, toolsState.knowHow, sources)
  /// while resetting workspace-specific state:
  ///   - toolsState.usageCount resets to 0 (metrics are workspace-specific).
  ///   - toolsMisconfigured resets to [] (operator errors are workspace-specific).
  ///   - secretOverrides resets to [] (overrides are workspace-scoped).
  ///
  /// The caller provides the new name, target workspace, secrets (old secrets are
  /// workspace-scoped and not portable), and optionally an execution type override.
  /// If executionType is null, the original's execution type is inherited.
  ///
  /// Note: `state` is the first parameter — follow this convention for all new model functions.
  public func forkAgent(
    state : AgentRegistryState,
    originalId : Nat,
    newName : Text,
    targetWorkspaceId : Nat,
    secretsAllowed : [(Nat, Types.SecretId)],
    secretOverrides : [(Types.SecretId, Text)],
    executionType : ?AgentExecutionType,
  ) : Result.Result<Nat, Text> {
    switch (Map.get(state.agentsById, Nat.compare, originalId)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(originalId) # " not found.");
      };
      case (?original) {
        // Carry over knowHow per tool; reset usageCount (workspace-specific metrics).
        let forkedToolsState = Map.empty<Text, ToolState>();
        for ((toolName, ts) in Map.entries(original.toolsState)) {
          Map.add(forkedToolsState, Text.compare, toolName, { usageCount = 0; knowHow = ts.knowHow });
        };
        register(
          newName,
          targetWorkspaceId,
          original.category,
          original.llmModel,
          switch (executionType) {
            case (?et) et;
            case null original.executionType;
          },
          secretsAllowed,
          secretOverrides,
          original.toolsDisallowed,
          [], // toolsMisconfigured resets — these are workspace-specific operator errors
          forkedToolsState,
          original.sources,
          state,
        );
      };
    };
  };

  /// Unregister an agent by ID.
  /// Returns `#err` if the agent is not found.
  public func unregisterById(id : Nat, state : AgentRegistryState) : Result.Result<Bool, Text> {
    switch (Map.get(state.agentsById, Nat.compare, id)) {
      case (null) {
        #err("Agent with ID " # Nat.toText(id) # " not found.");
      };
      case (?record) {
        Map.remove(state.agentsById, Nat.compare, id);
        Map.remove(state.agentsByName, Text.compare, record.name);
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
  public func getFirstByCategory(category : AgentCategory, state : AgentRegistryState) : ?AgentRecord {
    for (record in Map.values(state.agentsById)) {
      if (record.category == category) {
        return ?record;
      };
    };
    null;
  };

  /// Count all registered agents with the given category.
  public func countByCategory(category : AgentCategory, state : AgentRegistryState) : Nat {
    var count = 0;
    for (record in Map.values(state.agentsById)) {
      if (record.category == category) {
        count += 1;
      };
    };
    count;
  };

  /// Create the default agent registry state pre-seeded with the built-in
  /// workspace-admin agent (category = #admin, OpenRouter gpt_oss_120b).
  ///
  /// The default admin agent is granted access to the org-level (workspace 0)
  /// OpenRouter API key and Slack bot token, required for critical administrative tasks.
  ///
  /// Called once during canister initialization in main.mo.
  public func defaultState() : AgentRegistryState {
    let state = emptyState();
    ignore register(
      "workspace-admin",
      0, // owned by workspace 0 — org-wide agent
      #admin,
      #openRouter(#gpt_oss_120b),
      #api, // in-canister LLM loop
      [(0, #openRouterApiKey)],
      [], // secretOverrides — none for the built-in admin agent
      [],
      [],
      Map.empty<Text, ToolState>(),
      [],
      state,
    );
    state;
  };

  /// Map an LlmModel to the provider-specific model string used in API calls.
  public func llmModelToText(model : LlmModel) : Text {
    switch (model) {
      case (#openRouter(#gpt_oss_120b)) { "openai/gpt-oss-120b" };
    };
  };

  /// Map an LlmModel to the SecretId that holds the corresponding API key.
  public func llmModelToSecretId(model : LlmModel) : Types.SecretId {
    switch (model) {
      case (#openRouter(_)) { #openRouterApiKey };
    };
  };

  /// Return true if the agent has a secretsAllowed entry for (workspaceId, secretId).
  public func isSecretAllowed(agent : AgentRecord, workspaceId : Nat, secretId : Types.SecretId) : Bool {
    for ((wsId, sId) in agent.secretsAllowed.vals()) {
      if (wsId == workspaceId and sId == secretId) {
        return true;
      };
    };
    false;
  };

  // ============================================
  // Shareable view (crossing the shared boundary)
  // ============================================

  /// A serializable snapshot of an AgentRecord suitable for returning from
  /// shared (public) canister methods.  The mutable Map inside toolsState
  /// is flattened to an array of key-value pairs.
  public type AgentRecordView = {
    id : Nat;
    name : Text;
    workspaceId : Nat;
    category : AgentCategory;
    llmModel : LlmModel;
    executionType : AgentExecutionType;
    secretsAllowed : [(Nat, Types.SecretId)];
    secretOverrides : [(Types.SecretId, Text)];
    toolsDisallowed : [Text];
    toolsMisconfigured : [Text];
    toolsState : [(Text, ToolState)];
    sources : [Text];
  };

  /// Convert an AgentRecord to a shareable AgentRecordView.
  public func toView(record : AgentRecord) : AgentRecordView {
    {
      id = record.id;
      name = record.name;
      workspaceId = record.workspaceId;
      category = record.category;
      llmModel = record.llmModel;
      executionType = record.executionType;
      secretsAllowed = record.secretsAllowed;
      secretOverrides = record.secretOverrides;
      toolsDisallowed = record.toolsDisallowed;
      toolsMisconfigured = record.toolsMisconfigured;
      toolsState = Iter.toArray(Map.entries(record.toolsState));
      sources = record.sources;
    };
  };
};
