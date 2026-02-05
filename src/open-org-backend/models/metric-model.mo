import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import List "mo:core/List";

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

  /// Type alias for the metrics registry state (nextMetricId, Map<metricId, MetricRegistration>)
  public type MetricsRegistryState = (Nat, Map.Map<Nat, MetricRegistration>);

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
    (0, Map.empty<Nat, MetricRegistration>());
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

  /// Insert a datapoint into a sorted list (sorted by timestamp descending - newest first)
  /// Adds the datapoint and re-sorts the list to maintain descending timestamp order
  ///
  /// @param list - The list to insert into
  /// @param datapoint - The datapoint to insert
  /// @returns The updated list with the datapoint inserted in sorted position
  public func insertSorted(list : TimeBucket, datapoint : MetricDatapoint) : TimeBucket {
    // Add the new datapoint
    List.add(list, datapoint);

    // Sort in-place by timestamp descending (newest first)
    List.sortInPlace<MetricDatapoint>(
      list,
      func(a : MetricDatapoint, b : MetricDatapoint) : {
        #less;
        #equal;
        #greater;
      } {
        if (a.timestamp > b.timestamp) { #less } // reverse order for descending
        else if (a.timestamp < b.timestamp) { #greater } else { #equal };
      },
    );

    list;
  };

  /// Register a new metric
  ///
  /// @param registryState - The metrics registry state (nextId, registry)
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
    let (nextId, registry) = registryState;

    // Validate name
    if (input.name == "") {
      return #err("Metric name cannot be empty.");
    };

    // Validate retention days
    if (input.retentionDays < MIN_RETENTION_DAYS) {
      return #err("Retention days must be at least " # Nat.toText(MIN_RETENTION_DAYS) # ".");
    };
    if (input.retentionDays > MAX_RETENTION_DAYS) {
      return #err("Retention days cannot exceed " # Nat.toText(MAX_RETENTION_DAYS) # ".");
    };

    // Check for duplicate name
    let duplicate = Iter.find<MetricRegistration>(
      Map.values(registry),
      func(m : MetricRegistration) : Bool { m.name == input.name },
    );
    switch (duplicate) {
      case (?_) {
        return #err("A metric with this name already exists.");
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
    #ok(id);
  };

  /// Unregister a metric (removes from registry and clears datapoints)
  ///
  /// @param registryState - The metrics registry state (nextId, registry)
  /// @param datapoints - The datapoints store
  /// @param metricId - The metric ID to unregister
  /// @returns True if the metric was found and removed, false otherwise
  public func unregisterMetric(
    registryState : MetricsRegistryState,
    datapoints : MetricDatapointsStore,
    metricId : Nat,
  ) : Bool {
    let (_, registry) = registryState;
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
  /// @param registryState - The metrics registry state (nextId, registry)
  /// @param metricId - The metric ID
  /// @returns The metric registration if found
  public func getMetric(registryState : MetricsRegistryState, metricId : Nat) : ?MetricRegistration {
    let (_, registry) = registryState;
    Map.get(registry, Nat.compare, metricId);
  };

  /// List all registered metrics
  ///
  /// @param registryState - The metrics registry state (nextId, registry)
  /// @returns Array of all metric registrations
  public func listMetrics(registryState : MetricsRegistryState) : [MetricRegistration] {
    let (_, registry) = registryState;
    Iter.toArray(Map.values(registry));
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
    let (_, registry) = registryState;
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

    // Insert datapoint in sorted position
    let updatedBucket = insertSorted(timeBucket, datapoint);
    Map.add(buckets, Nat.compare, bucketKey, updatedBucket);

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
    var allDatapoints = List.empty<MetricDatapoint>();

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

    // Within the latest bucket, the first element is the newest (sorted descending)
    switch (latestBucket) {
      case (null) { null };
      case (?tb) { List.first(tb) };
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
    let (_, registry) = registryState;
    let now = Time.now();

    for ((metricId, buckets) in Map.entries(datapoints)) {
      switch (Map.get(registry, Nat.compare, metricId)) {
        case (null) {
          // Metric was deleted, remove all datapoints
          Map.remove(datapoints, Nat.compare, metricId);
        };
        case (?reg) {
          let retentionNanos : Int = reg.retentionDays * NANOS_PER_DAY;
          let cutoffTimestamp : Int = now - retentionNanos;
          let cutoffBucketKey = calculateBucketKey(cutoffTimestamp);

          // Collect bucket keys to remove (buckets entirely before cutoff)
          var bucketsToRemove = List.empty<Nat>();

          for ((bucketKey, timeBucket) in Map.entries(buckets)) {
            if (bucketKey < cutoffBucketKey) {
              // Entire bucket is before cutoff - delete it
              List.add(bucketsToRemove, bucketKey);
            } else if (bucketKey == cutoffBucketKey) {
              // Boundary bucket - filter datapoints within it
              var filteredBucket = List.empty<MetricDatapoint>();
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
