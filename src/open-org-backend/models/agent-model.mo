import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Types "../types";

module {
  public type Agent = {
    id : Nat;
    name : Text;
    provider : Types.LlmProvider;
    model : Text;
  };

  /// Type alias for workspace agents state with mutable nextId counter
  public type WorkspaceAgentsState = {
    var nextId : Nat;
    agents : Map.Map<Nat, Agent>;
  };

  /// Type alias for the full workspace agents map
  public type WorkspaceAgentsMap = Map.Map<Nat, WorkspaceAgentsState>;

  /// Create an empty workspace agents state
  public func emptyWorkspaceState() : WorkspaceAgentsState {
    {
      var nextId = 0;
      agents = Map.empty<Nat, Agent>();
    };
  };

  // Create a new agent
  public func createAgent(name : Text, provider : Types.LlmProvider, model : Text, workspaceState : WorkspaceAgentsState) : Result.Result<Nat, Text> {
    if (name == "") {
      return #err("Agent name cannot be empty.");
    };

    let id = workspaceState.nextId;
    let agent : Agent = {
      id;
      name;
      provider;
      model;
    };
    Map.add(workspaceState.agents, Nat.compare, id, agent);
    workspaceState.nextId += 1;
    #ok(id);
  };

  // Read/Get an agent
  public func getAgent(id : Nat, workspaceState : WorkspaceAgentsState) : ?Agent {
    Map.get(workspaceState.agents, Nat.compare, id);
  };

  // Update an agent
  public func updateAgent(id : Nat, newName : ?Text, newProvider : ?Types.LlmProvider, newModel : ?Text, workspaceState : WorkspaceAgentsState) : Result.Result<Bool, Text> {
    switch (Map.get(workspaceState.agents, Nat.compare, id)) {
      case (null) {
        #err("Agent not found.");
      };
      case (?existingAgent) {
        let updatedAgent : Agent = {
          id;
          name = switch (newName) {
            case (null) { existingAgent.name };
            case (?name) { name };
          };
          provider = switch (newProvider) {
            case (null) { existingAgent.provider };
            case (?provider) { provider };
          };
          model = switch (newModel) {
            case (null) { existingAgent.model };
            case (?model) { model };
          };
        };
        Map.add(workspaceState.agents, Nat.compare, id, updatedAgent);
        #ok(true);
      };
    };
  };

  // Delete an agent
  public func deleteAgent(id : Nat, workspaceState : WorkspaceAgentsState) : Result.Result<Bool, Text> {
    switch (Map.get(workspaceState.agents, Nat.compare, id)) {
      case (null) {
        #err("Agent not found.");
      };
      case (?_) {
        Map.remove(workspaceState.agents, Nat.compare, id);
        #ok(true);
      };
    };
  };

  // List all agents
  public func listAgents(workspaceState : WorkspaceAgentsState) : [Agent] {
    Iter.toArray(Map.values(workspaceState.agents));
  };
};
