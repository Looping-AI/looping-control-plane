import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Principal "mo:core/Principal";

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

  /// A structured plan for achieving the value stream's goal
  public type Plan = {
    summary : Text;
    currentState : Text;
    targetState : Text;
    steps : Text;
    risks : Text;
    resources : Text;
    createdAt : Int;
    updatedAt : Int;
  };

  /// Input for creating or updating a plan
  public type PlanInput = {
    summary : Text;
    currentState : Text;
    targetState : Text;
    steps : Text;
    risks : Text;
    resources : Text;
  };

  /// Author of a plan change
  public type PlanChangeAuthor = {
    #principal : Principal;
    #assistant : Text;
  };

  /// A record of a plan change
  public type PlanChange = {
    timestamp : Int;
    changedBy : PlanChangeAuthor;
    diff : Text;
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
    plan : ?Plan;
    planHistory : List.List<PlanChange>;
    createdAt : Int;
    updatedAt : Int;
  };

  /// Shareable version of ValueStream for canister API responses
  public type ShareableValueStream = {
    id : Nat;
    workspaceId : Nat;
    name : Text;
    problem : Text;
    goal : Text;
    status : ValueStreamStatus;
    plan : ?Plan;
    planHistory : [PlanChange];
    createdAt : Int;
    updatedAt : Int;
  };

  /// Convert a ValueStream to a ShareableValueStream
  public func toShareable(valueStream : ValueStream) : ShareableValueStream {
    {
      id = valueStream.id;
      workspaceId = valueStream.workspaceId;
      name = valueStream.name;
      problem = valueStream.problem;
      goal = valueStream.goal;
      status = valueStream.status;
      plan = valueStream.plan;
      planHistory = List.toArray(valueStream.planHistory);
      createdAt = valueStream.createdAt;
      updatedAt = valueStream.updatedAt;
    };
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
      plan = null;
      planHistory = List.empty<PlanChange>();
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
              plan = existing.plan;
              planHistory = existing.planHistory;
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

  // ============================================
  // Plan Management
  // ============================================

  /// Set or update the plan for a value stream
  /// Mutates the valueStream by replacing it in the map with updated version
  ///
  /// @param valueStreamsMap - The full value streams map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param input - The plan input
  /// @param changedBy - Who made the change
  /// @param diff - Description of what changed
  /// @returns Result indicating success or error
  public func setPlan(
    valueStreamsMap : ValueStreamsMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    input : PlanInput,
    changedBy : PlanChangeAuthor,
    diff : Text,
  ) : Result.Result<(), Text> {
    switch (Map.get(valueStreamsMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?(_nextId, streamsMap)) {
        switch (Map.get(streamsMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?existing) {
            let now = Time.now();

            // Create or update the plan
            let newPlan : Plan = {
              summary = input.summary;
              currentState = input.currentState;
              targetState = input.targetState;
              steps = input.steps;
              risks = input.risks;
              resources = input.resources;
              createdAt = switch (existing.plan) {
                case (null) { now };
                case (?p) { p.createdAt };
              };
              updatedAt = now;
            };

            // Create plan change record
            let planChange : PlanChange = {
              timestamp = now;
              changedBy;
              diff;
            };

            // Add to history (List.add mutates in place)
            List.add(existing.planHistory, planChange);

            // Update the value stream with new plan
            let updated : ValueStream = {
              id = existing.id;
              workspaceId = existing.workspaceId;
              name = existing.name;
              problem = existing.problem;
              goal = existing.goal;
              status = existing.status;
              plan = ?newPlan;
              planHistory = existing.planHistory;
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
};
