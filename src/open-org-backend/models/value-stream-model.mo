import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Iter "mo:core/Iter";

module {
  // ============================================
  // Types
  // ============================================

  /// Status of a value stream
  public type ValueStreamStatus = {
    #draft;
    #active;
    #paused;
    #archived;
  };

  /// A value stream represents a problem-goal pair
  /// Note: Objectives are managed separately in ObjectiveModel
  public type ValueStream = {
    id : Nat;
    workspaceId : Nat;
    name : Text;
    problem : Text;
    goal : Text;
    status : ValueStreamStatus;
    createdAt : Int;
    updatedAt : Int;
  };

  /// Input for creating a new value stream
  public type ValueStreamInput = {
    name : Text;
    problem : Text;
    goal : Text;
  };

  /// Type alias for workspace value streams state
  /// (nextValueStreamId, Map<valueStreamId, ValueStream>)
  public type WorkspaceValueStreamsState = (Nat, Map.Map<Nat, ValueStream>);

  /// Type alias for the full value streams map
  public type ValueStreamsMap = Map.Map<Nat, WorkspaceValueStreamsState>;

  // ============================================
  // State Helpers
  // ============================================

  /// Create an empty workspace value streams state
  public func emptyWorkspaceState() : WorkspaceValueStreamsState {
    (0, Map.empty<Nat, ValueStream>());
  };

  /// Create an empty value streams map
  public func emptyValueStreamsMap() : ValueStreamsMap {
    Map.empty<Nat, WorkspaceValueStreamsState>();
  };

  // ============================================
  // CRUD Functions
  // ============================================

  /// Create a new value stream in a workspace
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @param input - The value stream input
  /// @returns Result with the new value stream ID
  public func createValueStream(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
    input : ValueStreamInput,
  ) : Result.Result<Nat, Text> {
    // Validate input
    if (input.name == "") {
      return #err("Value stream name cannot be empty.");
    };
    if (input.problem == "") {
      return #err("Value stream problem cannot be empty.");
    };
    if (input.goal == "") {
      return #err("Value stream goal cannot be empty.");
    };

    // Get or create workspace state
    let (nextId, streamsMap) = switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { emptyWorkspaceState() };
      case (?state) { state };
    };

    let now = Time.now();
    let valueStream : ValueStream = {
      id = nextId;
      workspaceId;
      name = input.name;
      problem = input.problem;
      goal = input.goal;
      status = #draft;
      createdAt = now;
      updatedAt = now;
    };

    Map.add(streamsMap, Nat.compare, nextId, valueStream);
    Map.add(valueStreamsMap, Nat.compare, workspaceId, (nextId + 1, streamsMap));

    #ok(nextId);
  };

  /// Get a value stream by ID
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @returns Result with the value stream or error
  public func getValueStream(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : Result.Result<ValueStream, Text> {
    switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?(_, streamsMap)) {
        switch (Map.get(streamsMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?vs) { #ok(vs) };
        };
      };
    };
  };

  /// Update a value stream
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param newName - Optional new name
  /// @param newProblem - Optional new problem
  /// @param newGoal - Optional new goal
  /// @param newStatus - Optional new status
  /// @returns Result indicating success or error
  public func updateValueStream(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    newName : ?Text,
    newProblem : ?Text,
    newGoal : ?Text,
    newStatus : ?ValueStreamStatus,
  ) : Result.Result<(), Text> {
    switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?(_nextId, streamsMap)) {
        switch (Map.get(streamsMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?existing) {
            let now = Time.now();
            let updated : ValueStream = {
              id = existing.id;
              workspaceId = existing.workspaceId;
              name = switch (newName) {
                case (null) { existing.name };
                case (?n) { n };
              };
              problem = switch (newProblem) {
                case (null) { existing.problem };
                case (?p) { p };
              };
              goal = switch (newGoal) {
                case (null) { existing.goal };
                case (?g) { g };
              };
              status = switch (newStatus) {
                case (null) { existing.status };
                case (?s) { s };
              };
              createdAt = existing.createdAt;
              updatedAt = now;
            };
            Map.add(streamsMap, Nat.compare, valueStreamId, updated);
            #ok(());
          };
        };
      };
    };
  };

  /// Delete a value stream
  /// Note: Caller should also call ObjectiveModel.deleteValueStreamObjectives to clean up objectives
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @returns Result indicating success or error
  public func deleteValueStream(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : Result.Result<(), Text> {
    switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?(_nextId, streamsMap)) {
        switch (Map.get(streamsMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?_) {
            Map.remove(streamsMap, Nat.compare, valueStreamId);
            #ok(());
          };
        };
      };
    };
  };

  /// List all value streams in a workspace
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @returns Result with array of value streams or error
  public func listValueStreams(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
  ) : Result.Result<[ValueStream], Text> {
    switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?(_, streamsMap)) {
        #ok(Iter.toArray(Map.values(streamsMap)));
      };
    };
  };
};
