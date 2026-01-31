import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Time "mo:core/Time";

module {
  // ============================================
  // Types
  // ============================================

  /// Status of an objective
  public type ObjectiveStatus = {
    #active;
    #paused;
    #archived;
  };

  /// Direction for count-based targets
  public type ObjectiveTargetDirection = {
    #increase;
    #decrease;
  };

  /// Target definition for an objective
  public type ObjectiveTarget = {
    #percentage : { target : Float };
    #count : { target : Float; direction : ObjectiveTargetDirection };
    #threshold : { min : ?Float; max : ?Float };
    #boolean : Bool;
  };

  /// Author of a comment on an objective datapoint
  public type ObjectiveDatapointCommentAuthor = {
    #principal : Principal;
    #assistant : Text;
    #task : Text;
  };

  /// A comment attached to an objective datapoint
  public type ObjectiveDatapointComment = {
    timestamp : Int;
    author : ObjectiveDatapointCommentAuthor;
    message : Text;
  };

  /// A computed datapoint for an objective
  public type ObjectiveDatapoint = {
    timestamp : Int;
    value : ?Float;
    valueWarning : ?Text;
    comments : [ObjectiveDatapointComment];
  };

  /// An objective within a value stream
  public type Objective = {
    id : Nat;
    name : Text;
    description : ?Text;
    metricIds : [Nat];
    computation : Text; // TODO: to be improved with a proper way to run an eval function
    target : ObjectiveTarget;
    targetDate : ?Int;
    current : ?Float;
    history : List.List<ObjectiveDatapoint>; // Using List for O(1) prepend
    status : ObjectiveStatus;
    createdAt : Int;
    updatedAt : Int;
  };

  /// Shareable version of Objective for canister API responses
  /// Uses [ObjectiveDatapoint] instead of List.List for shared type compatibility
  public type ShareableObjective = {
    id : Nat;
    name : Text;
    description : ?Text;
    metricIds : [Nat];
    computation : Text;
    target : ObjectiveTarget;
    targetDate : ?Int;
    current : ?Float;
    history : [ObjectiveDatapoint];
    status : ObjectiveStatus;
    createdAt : Int;
    updatedAt : Int;
  };

  /// Convert an Objective to a ShareableObjective
  public func toShareable(objective : Objective) : ShareableObjective {
    {
      id = objective.id;
      name = objective.name;
      description = objective.description;
      metricIds = objective.metricIds;
      computation = objective.computation;
      target = objective.target;
      targetDate = objective.targetDate;
      current = objective.current;
      history = List.toArray(objective.history);
      status = objective.status;
      createdAt = objective.createdAt;
      updatedAt = objective.updatedAt;
    };
  };

  /// Input for creating a new objective
  public type ObjectiveInput = {
    name : Text;
    description : ?Text;
    metricIds : [Nat];
    computation : Text;
    target : ObjectiveTarget;
    targetDate : ?Int;
  };

  /// State for objectives within a value stream: (nextObjectiveId, objectives map)
  public type ValueStreamObjectivesState = (Nat, Map.Map<Nat, Objective>);

  /// Map from valueStreamId to objectives state
  public type WorkspaceObjectivesMap = Map.Map<Nat, ValueStreamObjectivesState>;

  /// Full objectives map: workspaceId -> (valueStreamId -> objectives state)
  public type ObjectivesMap = Map.Map<Nat, WorkspaceObjectivesMap>;

  // ============================================
  // State Helpers
  // ============================================

  /// Create an empty objectives map
  public func emptyObjectivesMap() : ObjectivesMap {
    Map.empty<Nat, WorkspaceObjectivesMap>();
  };

  /// Create an empty workspace objectives map
  public func emptyWorkspaceObjectivesMap() : WorkspaceObjectivesMap {
    Map.empty<Nat, ValueStreamObjectivesState>();
  };

  /// Create an empty value stream objectives state
  public func emptyValueStreamObjectivesState() : ValueStreamObjectivesState {
    (0, Map.empty<Nat, Objective>());
  };

  /// Initialize objectives state for a new value stream
  public func initValueStreamObjectives(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
  ) {
    let workspaceMap = switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { emptyWorkspaceObjectivesMap() };
      case (?wm) { wm };
    };

    // Only initialize if not already present
    switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
      case (null) {
        Map.add(workspaceMap, Nat.compare, valueStreamId, emptyValueStreamObjectivesState());
        Map.add(objectivesMap, Nat.compare, workspaceId, workspaceMap);
      };
      case (?_) {};
    };
  };

  /// Delete objectives state for a value stream (cleanup when value stream is deleted)
  public func deleteValueStreamObjectives(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
  ) {
    switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) {};
      case (?workspaceMap) {
        Map.remove(workspaceMap, Nat.compare, valueStreamId);
        Map.add(objectivesMap, Nat.compare, workspaceId, workspaceMap);
      };
    };
  };

  // ============================================
  // CRUD Functions
  // ============================================

  /// Add an objective to a value stream
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param input - The objective input
  /// @returns Result with the new objective ID
  public func addObjective(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    input : ObjectiveInput,
  ) : Result.Result<Nat, Text> {
    // Validate input
    if (input.name == "") {
      return #err("Objective name cannot be empty.");
    };
    if (input.metricIds.size() == 0) {
      return #err("Objective must have at least one metric.");
    };
    if (input.computation == "") {
      return #err("Objective computation cannot be empty.");
    };

    let workspaceMap = switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { return #err("Workspace not found.") };
      case (?wm) { wm };
    };

    let (nextId, objectives) = switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
      case (null) { return #err("Value stream not found.") };
      case (?state) { state };
    };

    let now = Time.now();
    let objective : Objective = {
      id = nextId;
      name = input.name;
      description = input.description;
      metricIds = input.metricIds;
      computation = input.computation;
      target = input.target;
      targetDate = input.targetDate;
      current = null;
      history = List.empty<ObjectiveDatapoint>();
      status = #active;
      createdAt = now;
      updatedAt = now;
    };

    // Add to the map (O(1))
    Map.add(objectives, Nat.compare, nextId, objective);

    // Update nextId counter
    Map.add(workspaceMap, Nat.compare, valueStreamId, (nextId + 1, objectives));

    #ok(nextId);
  };

  /// Get an objective by ID
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param objectiveId - The objective ID
  /// @returns Result with the objective or an error message
  public func getObjective(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : Result.Result<Objective, Text> {
    switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?workspaceMap) {
        switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?(_, objectives)) {
            switch (Map.get(objectives, Nat.compare, objectiveId)) {
              case (null) { #err("Objective not found.") };
              case (?o) { #ok(o) };
            };
          };
        };
      };
    };
  };

  /// List all objectives for a value stream
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @returns Result with array of objectives or an error message
  public func listObjectives(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
  ) : Result.Result<[Objective], Text> {
    switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { #err("Workspace not found.") };
      case (?workspaceMap) {
        switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
          case (null) { #err("Value stream not found.") };
          case (?(_, objectives)) {
            #ok(Iter.toArray(Map.values(objectives)));
          };
        };
      };
    };
  };

  /// Update an objective
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param objectiveId - The objective ID
  /// @param newName - Optional new name
  /// @param newDescription - Optional new description (use ?null to clear)
  /// @param newMetricIds - Optional new metric IDs
  /// @param newComputation - Optional new computation
  /// @param newTarget - Optional new target
  /// @param newTargetDate - Optional new target date (use ?null to clear)
  /// @param newStatus - Optional new status
  /// @returns Result indicating success or error
  public func updateObjective(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    newName : ?Text,
    newDescription : ??Text,
    newMetricIds : ?[Nat],
    newComputation : ?Text,
    newTarget : ?ObjectiveTarget,
    newTargetDate : ??Int,
    newStatus : ?ObjectiveStatus,
  ) : Result.Result<(), Text> {
    let workspaceMap = switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { return #err("Workspace not found.") };
      case (?wm) { wm };
    };

    let (_, objectives) = switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
      case (null) { return #err("Value stream not found.") };
      case (?state) { state };
    };

    // O(1) lookup by ID
    let o = switch (Map.get(objectives, Nat.compare, objectiveId)) {
      case (null) { return #err("Objective not found.") };
      case (?obj) { obj };
    };
    let now = Time.now();

    let updated : Objective = {
      id = o.id;
      name = switch (newName) { case (null) { o.name }; case (?n) { n } };
      description = switch (newDescription) {
        case (null) { o.description };
        case (?d) { d };
      };
      metricIds = switch (newMetricIds) {
        case (null) { o.metricIds };
        case (?m) { m };
      };
      computation = switch (newComputation) {
        case (null) { o.computation };
        case (?c) { c };
      };
      target = switch (newTarget) {
        case (null) { o.target };
        case (?t) { t };
      };
      targetDate = switch (newTargetDate) {
        case (null) { o.targetDate };
        case (?td) { td };
      };
      current = o.current;
      history = o.history;
      status = switch (newStatus) {
        case (null) { o.status };
        case (?s) { s };
      };
      createdAt = o.createdAt;
      updatedAt = now;
    };

    // O(1) update
    Map.add(objectives, Nat.compare, objectiveId, updated);

    #ok(());
  };

  /// Archive an objective (shorthand for updating status to #archived)
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param objectiveId - The objective ID
  /// @returns Result indicating success or error
  public func archiveObjective(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : Result.Result<(), Text> {
    updateObjective(
      objectivesMap,
      workspaceId,
      valueStreamId,
      objectiveId,
      null,
      null,
      null,
      null,
      null,
      null,
      ?#archived,
    );
  };

  /// Record a datapoint for an objective
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param objectiveId - The objective ID
  /// @param datapoint - The datapoint to record
  /// @returns Result indicating success or error
  public func recordObjectiveDatapoint(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    datapoint : ObjectiveDatapoint,
  ) : Result.Result<(), Text> {
    let workspaceMap = switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { return #err("Workspace not found.") };
      case (?wm) { wm };
    };

    let (_, objectives) = switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
      case (null) { return #err("Value stream not found.") };
      case (?state) { state };
    };

    // O(1) lookup by ID
    let o = switch (Map.get(objectives, Nat.compare, objectiveId)) {
      case (null) { return #err("Objective not found.") };
      case (?obj) { obj };
    };
    let now = Time.now();

    // Always create history entry from the datapoint and add to history
    let historyEntry : ObjectiveDatapoint = {
      timestamp = datapoint.timestamp;
      value = datapoint.value;
      valueWarning = datapoint.valueWarning;
      comments = datapoint.comments;
    };
    List.add(o.history, historyEntry);

    // Always update current with the new datapoint value
    let updated : Objective = {
      id = o.id;
      name = o.name;
      description = o.description;
      metricIds = o.metricIds;
      computation = o.computation;
      target = o.target;
      targetDate = o.targetDate;
      current = datapoint.value;
      history = o.history;
      status = o.status;
      createdAt = o.createdAt;
      updatedAt = now;
    };

    // O(1) update
    Map.add(objectives, Nat.compare, objectiveId, updated);

    #ok(());
  };

  /// Add a comment to a datapoint (pure function, does not persist)
  ///
  /// @param datapoint - The datapoint to add a comment to
  /// @param comment - The comment to add
  /// @returns Updated datapoint with the new comment
  public func addDatapointComment(
    datapoint : ObjectiveDatapoint,
    comment : ObjectiveDatapointComment,
  ) : ObjectiveDatapoint {
    {
      timestamp = datapoint.timestamp;
      value = datapoint.value;
      valueWarning = datapoint.valueWarning;
      comments = Array.concat(datapoint.comments, [comment]);
    };
  };

  /// Add a comment to a datapoint in an objective's history and persist it
  ///
  /// @param objectivesMap - The full objectives map
  /// @param workspaceId - The workspace ID
  /// @param valueStreamId - The value stream ID
  /// @param objectiveId - The objective ID
  /// @param historyIndex - The index of the datapoint in the history list (0 = oldest, last = most recent)
  /// @param comment - The comment to add
  /// @returns Result indicating success or error
  public func addCommentToHistoryDatapoint(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
    historyIndex : Nat,
    comment : ObjectiveDatapointComment,
  ) : Result.Result<(), Text> {
    let workspaceMap = switch (Map.get(objectivesMap, Nat.compare, workspaceId)) {
      case (null) { return #err("Workspace not found.") };
      case (?wm) { wm };
    };

    let (_, objectives) = switch (Map.get(workspaceMap, Nat.compare, valueStreamId)) {
      case (null) { return #err("Value stream not found.") };
      case (?state) { state };
    };

    // O(1) lookup by ID
    let o = switch (Map.get(objectives, Nat.compare, objectiveId)) {
      case (null) { return #err("Objective not found.") };
      case (?obj) { obj };
    };

    // Get the datapoint at index (O(1) access)
    let datapoint = switch (List.get(o.history, historyIndex)) {
      case (null) { return #err("History datapoint not found.") };
      case (?dp) { dp };
    };

    // Update with new comment
    let updatedDatapoint = addDatapointComment(datapoint, comment);

    // Put updated datapoint (O(1) update)
    List.put(o.history, historyIndex, updatedDatapoint);

    #ok(());
  };

  /// Get the size of the history list for an objective
  public func getHistorySize(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : Result.Result<Nat, Text> {
    switch (getObjective(objectivesMap, workspaceId, valueStreamId, objectiveId)) {
      case (#err(e)) { #err(e) };
      case (#ok(o)) { #ok(List.size(o.history)) };
    };
  };

  /// Get history as an array (for read-only operations)
  public func getHistoryArray(
    objectivesMap : ObjectivesMap,
    workspaceId : Nat,
    valueStreamId : Nat,
    objectiveId : Nat,
  ) : Result.Result<[ObjectiveDatapoint], Text> {
    switch (getObjective(objectivesMap, workspaceId, valueStreamId, objectiveId)) {
      case (#err(e)) { #err(e) };
      case (#ok(o)) { #ok(List.toArray(o.history)) };
    };
  };
};
