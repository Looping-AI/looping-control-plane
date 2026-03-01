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
    #admin; // org or workspace admin assistant
    #research; // information gathering and planning
    #communication; // drafting, summarizing, messaging
  };

  /// Groq-specific model variants.
  public type GroqModel = {
    #gpt_oss_120b; // Groq: gpt-oss-120b model
  };

  /// LLM provider + model pairing.
  /// Each provider has its own set of supported models.
  public type LlmModel = {
    #groq : GroqModel;
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
  ///   category        — determines the available tool catalogue and prompt strategy.
  ///   llmModel        — provider and model variant (e.g. #groq(#gpt_oss_120b)).
  ///   secretsAllowed  — explicit whitelist of (workspaceId, SecretId) pairs this agent may access.
  ///   toolsAllowed    — subset of category tools this agent may invoke.
  ///   toolsState      — per-tool runtime state (usageCount + knowHow text).
  ///   sources         — knowledge-source identifiers (URLs, doc refs, etc.) available to the agent.
  public type AgentRecord = {
    id : Nat;
    name : Text;
    category : AgentCategory;
    llmModel : LlmModel;
    secretsAllowed : [(Nat, Types.SecretId)];
    toolsAllowed : [Text];
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
    category : AgentCategory,
    llmModel : LlmModel,
    secretsAllowed : [(Nat, Types.SecretId)],
    toolsAllowed : [Text],
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
      category;
      llmModel;
      secretsAllowed;
      toolsAllowed;
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
    newSecretsAllowed : ?[(Nat, Types.SecretId)],
    newToolsAllowed : ?[Text],
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
          category = switch (newCategory) {
            case (null) { existing.category };
            case (?c) { c };
          };
          llmModel = switch (newLlmModel) {
            case (null) { existing.llmModel };
            case (?m) { m };
          };
          secretsAllowed = switch (newSecretsAllowed) {
            case (null) { existing.secretsAllowed };
            case (?s) { s };
          };
          toolsAllowed = switch (newToolsAllowed) {
            case (null) { existing.toolsAllowed };
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

  // ============================================
  // Shareable view (crossing the shared boundary)
  // ============================================

  /// A serializable snapshot of an AgentRecord suitable for returning from
  /// shared (public) canister methods.  The mutable Map inside toolsState
  /// is flattened to an array of key-value pairs.
  public type AgentRecordView = {
    id : Nat;
    name : Text;
    category : AgentCategory;
    llmModel : LlmModel;
    secretsAllowed : [(Nat, Types.SecretId)];
    toolsAllowed : [Text];
    toolsState : [(Text, ToolState)];
    sources : [Text];
  };

  /// Convert an AgentRecord to a shareable AgentRecordView.
  public func toView(record : AgentRecord) : AgentRecordView {
    {
      id = record.id;
      name = record.name;
      category = record.category;
      llmModel = record.llmModel;
      secretsAllowed = record.secretsAllowed;
      toolsAllowed = record.toolsAllowed;
      toolsState = Iter.toArray(Map.entries(record.toolsState));
      sources = record.sources;
    };
  };
};
