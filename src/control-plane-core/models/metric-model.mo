import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import List "mo:core/List";
import Runtime "mo:core/Runtime";

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

  /// Type alias for the metrics registry state with mutable nextId counter
  public type MetricsRegistryState = {
    var nextId : Nat;
    registry : Map.Map<Nat, MetricRegistration>;
  };

  /// Type alias for a time bucket (stores datapoints for a single day, sorted by timestamp)
  public type TimeBucket = List.List<MetricDatapoint>;

  /// Type alias for metric buckets (map from bucket key to time bucket)
  public type MetricBuckets = Map.Map<Nat, TimeBucket>;

  /// Type alias for the metric datapoints store (metricId -> buckets)
  public type MetricDatapointsStore = Map.Map<Nat, MetricBuckets>;

  // ============================================
  // Registry Functions
  // ============================================

  /// Create an empty metrics registry state
  public func emptyRegistry() : MetricsRegistryState {
    {
      var nextId = 0;
      registry = Map.empty<Nat, MetricRegistration>();
    };
  };

  /// Create an empty datapoints store
  public func emptyDatapoints() : MetricDatapointsStore {
    Map.empty<Nat, MetricBuckets>();
  };

  // ============================================
  // Bucket Helpers
  // ============================================

  /// Calculate the bucket key for a given timestamp (days since epoch)
  ///
  /// @param timestamp - The timestamp in nanoseconds
  /// @returns The bucket key (day number)
  public func calculateBucketKey(timestamp : Int) : Nat {
    Int.abs(timestamp / NANOS_PER_DAY);
  };

  /// Insert a datapoint into a sorted list (sorted by timestamp ascending - smallest first)
  /// Optimized to avoid sorting when the datapoint is bigger than all existing datapoints
  /// Mutates the list in place.
  ///
  /// @param list - The list to insert into
  /// @param datapoint - The datapoint to insert
  public func insertSorted(list : TimeBucket, datapoint : MetricDatapoint) {
    // Get last before insertion
    let currentLast = List.last(list);

    // Always add (appends to end)
    List.add(list, datapoint);
    if (List.size(list) == 1) {
      return; // First element, no need to sort
    };

    // Optimization: if new datapoint is bigger than or equal to the previously last element,
    // we can skip sorting (common case for real-time metrics)
    let last = switch (currentLast) {
      case (null) { Runtime.unreachable() };
      case (?last) { last };
    };
    if (datapoint.timestamp >= last.timestamp) {
      return; // it's already sorted ascending
    }
    // Otherwise, we need to sort
    else {
      // Sort in-place by timestamp ascending (smallest first)
      List.sortInPlace<MetricDatapoint>(
        list,
        func(a : MetricDatapoint, b : MetricDatapoint) : {
          #less;
          #equal;
          #greater;
        } {
          if (a.timestamp < b.timestamp) { #less } // ascending order
          else if (a.timestamp > b.timestamp) { #greater } else { #equal };
        },
      );
    };
  };

  // ============================================
  // Private Validation Helpers
  // ============================================

  /// Validate metric name is not empty
  ///
  /// @param name - The name to validate
  /// @returns Result indicating success or error
  private func validateName(name : Text) : Result.Result<(), Text> {
    if (name == "") {
      return #err("Metric name cannot be empty.");
    };
    #ok(());
  };

  /// Validate retention days are within bounds
  ///
  /// @param days - The retention days to validate
  /// @returns Result indicating success or error
  private func validateRetentionDays(days : Nat) : Result.Result<(), Text> {
    if (days < MIN_RETENTION_DAYS) {
      return #err("Retention days must be at least " # Nat.toText(MIN_RETENTION_DAYS) # ".");
    };
    if (days > MAX_RETENTION_DAYS) {
      return #err("Retention days cannot exceed " # Nat.toText(MAX_RETENTION_DAYS) # ".");
    };
    #ok(());
  };

  /// Check if a metric name already exists (optionally excluding a specific metric ID)
  ///
  /// @param registryState - The metrics registry state
  /// @param name - The name to check
  /// @param excludeId - Optional metric ID to exclude from the check (for updates)
  /// @returns Result indicating success or error
  private func checkDuplicateName(
    registryState : MetricsRegistryState,
    name : Text,
    excludeId : ?Nat,
  ) : Result.Result<(), Text> {
    let duplicate = Iter.find<MetricRegistration>(
      Map.values(registryState.registry),
      func(m : MetricRegistration) : Bool {
        switch (excludeId) {
          case (null) { m.name == name };
          case (?id) { m.name == name and m.id != id };
        };
      },
    );
    switch (duplicate) {
      case (?_) { #err("A metric with this name already exists.") };
      case (null) { #ok(()) };
    };
  };

  /// Register a new metric
  ///
  /// @param registryState - The metrics registry state with mutable nextId
  /// @param input - The metric registration input
  /// @param caller - The principal registering the metric
  /// @param now - Current timestamp
  /// @returns Result with new metric ID
  public func registerMetric(
    registryState : MetricsRegistryState,
    input : MetricRegistrationInput,
    caller : Principal,
    now : Int,
  ) : Result.Result<Nat, Text> {
    // Validate name
    switch (validateName(input.name)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(())) {};
    };

    // Validate retention days
    switch (validateRetentionDays(input.retentionDays)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(())) {};
    };

    // Check for duplicate name
    switch (checkDuplicateName(registryState, input.name, null)) {
      case (#err(msg)) { return #err(msg) };
      case (#ok(())) {};
    };

    let id = registryState.nextId;
    let registration : MetricRegistration = {
      id;
      name = input.name;
      description = input.description;
      unit = input.unit;
      retentionDays = input.retentionDays;
      createdBy = caller;
      createdAt = now;
    };

    Map.add(registryState.registry, Nat.compare, id, registration);
    registryState.nextId += 1;
    #ok(id);
  };

  /// Update an existing metric's configuration
  ///
  /// @param registryState - The metrics registry state
  /// @param metricId - The metric ID to update
  /// @param name - Optional new name
  /// @param description - Optional new description
  /// @param unit - Optional new unit
  /// @param retentionDays - Optional new retention period
  /// @returns Result indicating success or error
  public func updateMetric(
    registryState : MetricsRegistryState,
    metricId : Nat,
    name : ?Text,
    description : ?Text,
    unit : ?Text,
    retentionDays : ?Nat,
  ) : Result.Result<(), Text> {
    // Get existing metric
    let existing = switch (Map.get(registryState.registry, Nat.compare, metricId)) {
      case (null) { return #err("Metric not found.") };
      case (?m) { m };
    };

    // Validate and determine new name
    let newName = switch (name) {
      case (null) { existing.name };
      case (?n) {
        // Validate name
        switch (validateName(n)) {
          case (#err(msg)) { return #err(msg) };
          case (#ok(())) {};
        };
        // Check for duplicate name (only if name is actually changing)
        if (n != existing.name) {
          switch (checkDuplicateName(registryState, n, ?metricId)) {
            case (#err(msg)) { return #err(msg) };
            case (#ok(())) {};
          };
        };
        n;
      };
    };

    // Validate and determine new retention days
    let newRetentionDays = switch (retentionDays) {
      case (null) { existing.retentionDays };
      case (?r) {
        switch (validateRetentionDays(r)) {
          case (#err(msg)) { return #err(msg) };
          case (#ok(())) {};
        };
        r;
      };
    };

    // Create updated registration (preserve id, createdBy, createdAt)
    let updated : MetricRegistration = {
      id = existing.id;
      name = newName;
      description = switch (description) {
        case (null) { existing.description };
        case (?d) { d };
      };
      unit = switch (unit) {
        case (null) { existing.unit };
        case (?u) { u };
      };
      retentionDays = newRetentionDays;
      createdBy = existing.createdBy;
      createdAt = existing.createdAt;
    };

    // Update in registry
    Map.add(registryState.registry, Nat.compare, metricId, updated);
    #ok(());
  };

  /// Unregister a metric (removes from registry and clears datapoints)
  ///
  /// @param registryState - The metrics registry state with mutable nextId
  /// @param datapoints - The datapoints store
  /// @param metricId - The metric ID to unregister
  /// @returns True if the metric was found and removed, false otherwise
  public func unregisterMetric(
    registryState : MetricsRegistryState,
    datapoints : MetricDatapointsStore,
    metricId : Nat,
  ) : Bool {
    switch (Map.get(registryState.registry, Nat.compare, metricId)) {
      case (null) { false };
      case (?_) {
        Map.remove(registryState.registry, Nat.compare, metricId);
        Map.remove(datapoints, Nat.compare, metricId);
        true;
      };
    };
  };

  /// Get a metric registration by ID
  ///
  /// @param registryState - The metrics registry state with mutable nextId
  /// @param metricId - The metric ID
  /// @returns The metric registration if found
  public func getMetric(registryState : MetricsRegistryState, metricId : Nat) : ?MetricRegistration {
    Map.get(registryState.registry, Nat.compare, metricId);
  };

  /// List all registered metrics
  ///
  /// @param registryState - The metrics registry state with mutable nextId
  /// @returns Array of all metric registrations
  public func listMetrics(registryState : MetricsRegistryState) : [MetricRegistration] {
    Iter.toArray(Map.values(registryState.registry));
  };

  // ============================================
  // Datapoint Functions
  // ============================================

  /// Record a new datapoint for a metric
  ///
  /// @param datapoints - The datapoints store
  /// @param registryState - The metrics registry state (to validate metric exists)
  /// @param metricId - The metric ID
  /// @param value - The value to record
  /// @param source - The source of the datapoint
  /// @param timestamp - The timestamp of the datapoint
  /// @returns Result indicating success or error
  public func recordDatapoint(
    datapoints : MetricDatapointsStore,
    registryState : MetricsRegistryState,
    metricId : Nat,
    value : Float,
    source : MetricSource,
    timestamp : Int,
  ) : Result.Result<(), Text> {
    // Validate metric exists
    switch (Map.get(registryState.registry, Nat.compare, metricId)) {
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

    // Get or create metric buckets
    let buckets = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) {
        let newBuckets = Map.empty<Nat, TimeBucket>();
        Map.add(datapoints, Nat.compare, metricId, newBuckets);
        newBuckets;
      };
      case (?b) { b };
    };

    // Calculate bucket key (day)
    let bucketKey = calculateBucketKey(timestamp);

    // Get or create time bucket for this day
    let timeBucket = switch (Map.get(buckets, Nat.compare, bucketKey)) {
      case (null) { List.empty<MetricDatapoint>() };
      case (?tb) { tb };
    };

    // Insert datapoint in sorted position (mutates timeBucket in place)
    insertSorted(timeBucket, datapoint);
    Map.add(buckets, Nat.compare, bucketKey, timeBucket);

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
    let buckets = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) { return [] };
      case (?b) { b };
    };

    // Collect datapoints from all buckets
    let allDatapoints = List.empty<MetricDatapoint>();

    switch (since) {
      case (null) {
        // No filter - collect all datapoints from all buckets
        for ((_, timeBucket) in Map.entries(buckets)) {
          List.append(allDatapoints, timeBucket);
        };
      };
      case (?minTimestamp) {
        // Filter by timestamp - only scan relevant buckets
        let minBucketKey = calculateBucketKey(minTimestamp);

        for ((bucketKey, timeBucket) in Map.entries(buckets)) {
          if (bucketKey < minBucketKey) {
            // Skip buckets entirely before the cutoff
          } else if (bucketKey == minBucketKey) {
            // Boundary bucket - filter datapoints within it
            let bucketArray = List.toArray(timeBucket);
            for (dp in bucketArray.vals()) {
              if (dp.timestamp >= minTimestamp) {
                List.add(allDatapoints, dp);
              };
            };
          } else {
            // Buckets after minBucketKey - add all datapoints without filtering
            List.append(allDatapoints, timeBucket);
          };
        };
      };
    };

    List.toArray(allDatapoints);
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
    let buckets = switch (Map.get(datapoints, Nat.compare, metricId)) {
      case (null) { return null };
      case (?b) { b };
    };

    // Find the bucket with the highest key (most recent day)
    var maxBucketKey : ?Nat = null;
    var latestBucket : ?TimeBucket = null;

    for ((bucketKey, timeBucket) in Map.entries(buckets)) {
      switch (maxBucketKey) {
        case (null) {
          maxBucketKey := ?bucketKey;
          latestBucket := ?timeBucket;
        };
        case (?currentMax) {
          if (bucketKey > currentMax) {
            maxBucketKey := ?bucketKey;
            latestBucket := ?timeBucket;
          };
        };
      };
    };

    // Within the latest bucket, the last element is the biggest (sorted ascending)
    switch (latestBucket) {
      case (null) { null };
      case (?tb) { List.last(tb) };
    };
  };

  /// Count total datapoints across all metrics
  ///
  /// @param datapoints - The datapoints store
  /// @returns Total count of all datapoints
  public func totalDatapointsCount(datapoints : MetricDatapointsStore) : Nat {
    var total : Nat = 0;
    for ((_, buckets) in Map.entries(datapoints)) {
      for ((_, timeBucket) in Map.entries(buckets)) {
        total += List.size(timeBucket);
      };
    };
    total;
  };

  /// Purge datapoints older than their metric's retention period
  ///
  /// @param datapoints - The datapoints store
  /// @param registryState - The metrics registry state
  /// @returns Updated datapoints store (also mutates in place)
  public func purgeOldDatapoints(
    datapoints : MetricDatapointsStore,
    registryState : MetricsRegistryState,
  ) : MetricDatapointsStore {
    let now = Time.now();

    for ((metricId, buckets) in Map.entries(datapoints)) {
      switch (Map.get(registryState.registry, Nat.compare, metricId)) {
        case (null) {
          // Metric was deleted, remove all datapoints
          Map.remove(datapoints, Nat.compare, metricId);
        };
        case (?reg) {
          let retentionNanos : Int = reg.retentionDays * NANOS_PER_DAY;
          let cutoffTimestamp : Int = now - retentionNanos;
          let cutoffBucketKey = calculateBucketKey(cutoffTimestamp);

          // Collect bucket keys to remove (buckets entirely before cutoff)
          let bucketsToRemove = List.empty<Nat>();

          for ((bucketKey, timeBucket) in Map.entries(buckets)) {
            if (bucketKey < cutoffBucketKey) {
              // Entire bucket is before cutoff - delete it
              List.add(bucketsToRemove, bucketKey);
            } else if (bucketKey == cutoffBucketKey) {
              // Boundary bucket - filter datapoints within it
              let filteredBucket = List.empty<MetricDatapoint>();
              let bucketArray = List.toArray(timeBucket);

              for (dp in bucketArray.vals()) {
                if (dp.timestamp >= cutoffTimestamp) {
                  List.add(filteredBucket, dp);
                };
              };

              // Update or remove bucket
              if (List.isEmpty(filteredBucket)) {
                List.add(bucketsToRemove, bucketKey);
              } else {
                Map.add(buckets, Nat.compare, bucketKey, filteredBucket);
              };
            };
            // Buckets after cutoffBucketKey are kept as-is
          };

          // Remove old buckets
          let toRemoveArray = List.toArray(bucketsToRemove);
          for (bucketKey in toRemoveArray.vals()) {
            Map.remove(buckets, Nat.compare, bucketKey);
          };
        };
      };
    };

    datapoints;
  };
};
