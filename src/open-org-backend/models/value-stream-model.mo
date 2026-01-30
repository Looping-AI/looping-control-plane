import Principal "mo:core/Principal";

module {
  // ============================================
  // Types - ValueStream
  // ============================================

  /// Status of a value stream
  public type ValueStreamStatus = {
    #draft;
    #active;
    #paused;
    #archived;
  };

  /// A value stream represents a problem-goal pair with objectives to measure progress
  public type ValueStream = {
    id : Nat;
    workspaceId : Nat;
    name : Text;
    problem : Text;
    goal : Text;
    status : ValueStreamStatus;
    objectives : [Objective];
    nextObjectiveId : Nat;
    createdAt : Int;
    updatedAt : Int;
  };

  // ============================================
  // Types - Objective
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
    computation : Text;
    target : ObjectiveTarget;
    targetDate : ?Int;
    current : ?Float;
    history : [ObjectiveDatapoint];
    status : ObjectiveStatus;
    createdAt : Int;
    updatedAt : Int;
  };

  // ============================================
  // Input Types
  // ============================================

  /// Input for creating a new value stream
  public type ValueStreamInput = {
    name : Text;
    problem : Text;
    goal : Text;
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
};
