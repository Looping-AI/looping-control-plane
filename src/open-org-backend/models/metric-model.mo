import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Array "mo:core/Array";
import Result "mo:core/Result";
import Principal "mo:core/Principal";

module {
  // ============================================
  // Constants
  // ============================================

  /// Minimum retention period for metric datapoints (30 days)
  public let MIN_RETENTION_DAYS : Nat = 30;

  /// Maximum retention period for metric datapoints (5 years)
  public let MAX_RETENTION_DAYS : Nat = 1825;

  /// Nanoseconds per day (for retention calculations)
  public let NANOS_PER_DAY : Nat = 86_400_000_000_000;

  // ============================================
  // Types
  // ============================================

  /// Source of a metric datapoint
  public type MetricSource = {
    #manual : Text;
    #integration : Text;
    #evaluator : Text;
    #other : Text;
  };

  /// A single datapoint for a metric
  public type MetricDatapoint = {
    timestamp : Int;
    value : Float;
    source : MetricSource;
  };

  /// Registration info for a metric in the org-level registry
  public type MetricRegistration = {
    id : Nat;
    name : Text;
    description : Text;
    unit : Text;
    retentionDays : Nat;
    createdBy : Principal;
    createdAt : Int;
  };

  /// Input for registering a new metric (without id and createdAt)
  public type MetricRegistrationInput = {
    name : Text;
    description : Text;
    unit : Text;
    retentionDays : Nat;
  };

  /// Type alias for the metrics registry
  public type MetricsRegistry = Map.Map<Nat, MetricRegistration>;

  /// Type alias for the metric datapoints store
  public type MetricDatapointsStore = Map.Map<Nat, [MetricDatapoint]>;

  // ============================================
  // Registry Functions
  // ============================================

  /// Create an empty metrics registry
  public func emptyRegistry() : MetricsRegistry {
    Map.empty<Nat, MetricRegistration>();
  };

  /// Create an empty datapoints store
  public func emptyDatapoints() : MetricDatapointsStore {
    Map.empty<Nat, [MetricDatapoint]>();
  };

  /// Register a new metric
  ///
  /// @param registry - The metrics registry
  /// @param nextId - The next available metric ID
  /// @param input - The metric registration input
  /// @param caller - The principal registering the metric
  /// @param now - Current timestamp
  /// @returns Result with new metric ID, and the updated nextId
  public func registerMetric(
    registry : MetricsRegistry,
    nextId : Nat,
    input : MetricRegistrationInput,
    caller : Principal,
    now : Int,
  ) : (Result.Result<Nat, Text>, Nat) {
    // Validate name
    if (input.name == "") {
      return (#err("Metric name cannot be empty."), nextId);
    };

    // Validate retention days
    if (input.retentionDays < MIN_RETENTION_DAYS) {
      return (#err("Retention days must be at least " # Nat.toText(MIN_RETENTION_DAYS) # "."), nextId);
    };
    if (input.retentionDays > MAX_RETENTION_DAYS) {
      return (#err("Retention days cannot exceed " # Nat.toText(MAX_RETENTION_DAYS) # "."), nextId);
    };

    // Check for duplicate name
    let duplicate = Iter.find<MetricRegistration>(
      Map.values(registry),
      func(m : MetricRegistration) : Bool { m.name == input.name },
    );
    switch (duplicate) {
      case (?_) {
        return (#err("A metric with this name already exists."), nextId);
      };
      case (null) {};
    };

    let id = nextId;
    let registration : MetricRegistration = {
      id;
      name = input.name;
      description = input.description;
      unit = input.unit;
      retentionDays = input.retentionDays;
      createdBy = caller;
      createdAt = now;
    };

    Map.add(registry, Nat.compare, id, registration);
    (#ok(id), nextId + 1);
  };

  /// Unregister a metric (removes from registry and clears datapoints)
  ///
  /// @param registry - The metrics registry
  /// @param datapoints - The datapoints store
  /// @param metricId - The metric ID to unregister
  /// @returns True if the metric was found and removed, false otherwise
  public func unregisterMetric(
    registry : MetricsRegistry,
    datapoints : MetricDatapointsStore,
    metricId : Nat,
  ) : Bool {
    switch (Map.get(registry, Nat.compare, metricId)) {
      case (null) { false };
      case (?_) {
        Map.remove(registry, Nat.compare, metricId);
        Map.remove(datapoints, Nat.compare, metricId);
        true;
      };
    };
  };

  /// Get a metric registration by ID
  ///
  /// @param registry - The metrics registry
  /// @param metricId - The metric ID
  /// @returns The metric registration if found
  public func getMetric(registry : MetricsRegistry, metricId : Nat) : ?MetricRegistration {
    Map.get(registry, Nat.compare, metricId);
  };

  /// List all registered metrics
  ///
  /// @param registry - The metrics registry
  /// @returns Array of all metric registrations
  public func listMetrics(registry : MetricsRegistry) : [MetricRegistration] {
    Iter.toArray(Map.values(registry));
  };

  // ============================================
  // Datapoint Functions
  // ============================================

  /// Record a new datapoint for a metric
  ///
  /// @param datapoints - The datapoints store
  /// @param registry - The metrics registry (to validate metric exists)
  /// @param metricId - The metric ID
  /// @param value - The value to record
  /// @param source - The source of the datapoint
  /// @param timestamp - The timestamp of the datapoint
  /// @returns Result indicating success or error
  public func recordDatapoint(
    datapoints : MetricDatapointsStore,
    registry : MetricsRegistry,
    metricId : Nat,
    value : Float,
    source : MetricSource,
    timestamp : Int,
  ) : Result.Result<(), Text> {
    // Validate metric exists
    switch (Map.get(registry, Nat.compare, metricId)) {
      case (null) {
        return #err("Metric not found.");
      };
      case (?_) {};
    };

    let datapoint : MetricDatapoint = {
      timestamp;
      value;
      source;
    };

    let existingDatapoints = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) { [] };
      case (?dps) { dps };
    };

    // Append new datapoint
    let updatedDatapoints = Array.concat(existingDatapoints, [datapoint]);
    Map.add(datapoints, Nat.compare, metricId, updatedDatapoints);

    #ok(());
  };

  /// Get datapoints for a metric, optionally filtered by timestamp
  ///
  /// @param datapoints - The datapoints store
  /// @param metricId - The metric ID
  /// @param since - Optional minimum timestamp filter
  /// @returns Array of datapoints
  public func getDatapoints(
    datapoints : MetricDatapointsStore,
    metricId : Nat,
    since : ?Int,
  ) : [MetricDatapoint] {
    let dps = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) { return [] };
      case (?d) { d };
    };

    switch (since) {
      case (null) { dps };
      case (?minTimestamp) {
        Array.filter<MetricDatapoint>(dps, func(dp) { dp.timestamp >= minTimestamp });
      };
    };
  };

  /// Get the latest datapoint for a metric
  ///
  /// @param datapoints - The datapoints store
  /// @param metricId - The metric ID
  /// @returns The latest datapoint if any exist
  public func getLatestDatapoint(
    datapoints : MetricDatapointsStore,
    metricId : Nat,
  ) : ?MetricDatapoint {
    let dps = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) { return null };
      case (?d) { d };
    };

    if (Array.size(dps) == 0) {
      return null;
    };

    // Find datapoint with maximum timestamp
    var latest : ?MetricDatapoint = ?dps[0];
    var maxTimestamp : Int = dps[0].timestamp;

    for (dp in dps.vals()) {
      if (dp.timestamp > maxTimestamp) {
        maxTimestamp := dp.timestamp;
        latest := ?dp;
      };
    };

    latest;
  };

  /// Purge datapoints older than their metric's retention period
  ///
  /// @param datapoints - The datapoints store
  /// @param registry - The metrics registry
  /// @param now - Current timestamp
  /// @returns Updated datapoints store (also mutates in place)
  public func purgeOldDatapoints(
    datapoints : MetricDatapointsStore,
    registry : MetricsRegistry,
    now : Int,
  ) : MetricDatapointsStore {
    label purgeLoop for ((metricId, dps) in Map.entries(datapoints)) {
      switch (Map.get(registry, Nat.compare, metricId)) {
        case (null) {
          // Metric was deleted, remove all datapoints
          Map.remove(datapoints, Nat.compare, metricId);
        };
        case (?reg) {
          let retention = reg.retentionDays;
          let cutoffTimestamp = now - (retention * NANOS_PER_DAY);
          let filtered = Array.filter<MetricDatapoint>(
            dps,
            func(dp) { dp.timestamp >= cutoffTimestamp },
          );
          Map.add(datapoints, Nat.compare, metricId, filtered);
        };
      };
    };

    datapoints;
  };
};
