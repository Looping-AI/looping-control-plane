import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import MetricModel "../../../../src/open-org-backend/models/metric-model";

// Helper functions for Result comparison
func resultNatToText(r : Result.Result<Nat, Text>) : Text {
  switch (r) {
    case (#ok n) { "#ok(" # Nat.toText(n) # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultNatEqual(r1 : Result.Result<Nat, Text>, r2 : Result.Result<Nat, Text>) : Bool {
  r1 == r2;
};

func resultUnitToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultUnitEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

// Test data
let testPrincipal = Principal.fromText("aaaaa-aa");
let testTimestamp : Int = 1_000_000_000_000_000_000; // 1 second in nanoseconds

suite(
  "MetricModel - Constants",
  func() {
    test(
      "MIN_RETENTION_DAYS is 30",
      func() {
        expect.nat(MetricModel.MIN_RETENTION_DAYS).equal(30);
      },
    );

    test(
      "MAX_RETENTION_DAYS is 1825 (5 years)",
      func() {
        expect.nat(MetricModel.MAX_RETENTION_DAYS).equal(1825);
      },
    );
  },
);

suite(
  "MetricModel - Registry",
  func() {
    test(
      "emptyRegistry creates an empty map",
      func() {
        let registry = MetricModel.emptyRegistry();
        let metrics = MetricModel.listMetrics(registry);
        expect.nat(metrics.size()).equal(0);
      },
    );

    test(
      "registerMetric creates a new metric with valid input",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "response_time";
          description = "API response time";
          unit = "ms";
          retentionDays = 90;
        };

        let (result, newNextId) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
        expect.nat(newNextId).equal(1);

        let metrics = MetricModel.listMetrics(registry);
        expect.nat(metrics.size()).equal(1);
      },
    );

    test(
      "registerMetric rejects empty name",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Metric name cannot be empty.")
        );
      },
    );

    test(
      "registerMetric rejects retention below minimum",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "test_metric";
          description = "Test";
          unit = "count";
          retentionDays = 10; // Below 30
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Retention days must be at least 30.")
        );
      },
    );

    test(
      "registerMetric rejects retention above maximum",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "test_metric";
          description = "Test";
          unit = "count";
          retentionDays = 2000; // Above 1825
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Retention days cannot exceed 1825.")
        );
      },
    );

    test(
      "registerMetric rejects duplicate names",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "duplicate_metric";
          description = "First";
          unit = "count";
          retentionDays = 90;
        };

        let (_, nextId) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        let input2 : MetricModel.MetricRegistrationInput = {
          name = "duplicate_metric";
          description = "Second";
          unit = "ms";
          retentionDays = 60;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          nextId,
          input2,
          testPrincipal,
          testTimestamp,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("A metric with this name already exists.")
        );
      },
    );

    test(
      "getMetric returns registered metric",
      func() {
        let registry = MetricModel.emptyRegistry();
        let input : MetricModel.MetricRegistrationInput = {
          name = "get_test";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        switch (result) {
          case (#ok(id)) {
            let metric = MetricModel.getMetric(registry, id);
            switch (metric) {
              case (?m) {
                expect.text(m.name).equal("get_test");
                expect.text(m.unit).equal("count");
                expect.nat(m.retentionDays).equal(90);
              };
              case (null) {
                expect.bool(false).equal(true); // Force fail
              };
            };
          };
          case (#err(_)) {
            expect.bool(false).equal(true); // Force fail
          };
        };
      },
    );

    test(
      "getMetric returns null for non-existent metric",
      func() {
        let registry = MetricModel.emptyRegistry();
        let metric = MetricModel.getMetric(registry, 999);
        expect.bool(metric == null).equal(true);
      },
    );

    test(
      "unregisterMetric removes metric and its datapoints",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();

        let input : MetricModel.MetricRegistrationInput = {
          name = "to_delete";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        switch (result) {
          case (#ok(id)) {
            // Add a datapoint
            ignore MetricModel.recordDatapoint(
              datapoints,
              registry,
              id,
              42.0,
              #manual("test"),
              testTimestamp,
            );

            // Unregister
            let removed = MetricModel.unregisterMetric(registry, datapoints, id);
            expect.bool(removed).equal(true);

            // Verify metric is gone
            let metric = MetricModel.getMetric(registry, id);
            expect.bool(metric == null).equal(true);

            // Verify datapoints are gone
            let dps = MetricModel.getDatapoints(datapoints, id, null);
            expect.nat(dps.size()).equal(0);
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "unregisterMetric returns false for non-existent metric",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();
        let removed = MetricModel.unregisterMetric(registry, datapoints, 999);
        expect.bool(removed).equal(false);
      },
    );
  },
);

suite(
  "MetricModel - Datapoints",
  func() {
    test(
      "recordDatapoint stores a datapoint",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();

        let input : MetricModel.MetricRegistrationInput = {
          name = "datapoint_test";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        switch (result) {
          case (#ok(id)) {
            let recordResult = MetricModel.recordDatapoint(
              datapoints,
              registry,
              id,
              123.45,
              #integration("api"),
              testTimestamp,
            );

            expect.result<(), Text>(recordResult, resultUnitToText, resultUnitEqual).isOk();

            let dps = MetricModel.getDatapoints(datapoints, id, null);
            expect.nat(dps.size()).equal(1);
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "recordDatapoint fails for non-existent metric",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();

        let result = MetricModel.recordDatapoint(
          datapoints,
          registry,
          999,
          100.0,
          #manual("test"),
          testTimestamp,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Metric not found.")
        );
      },
    );

    test(
      "getDatapoints with since filter returns filtered results",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();

        let input : MetricModel.MetricRegistrationInput = {
          name = "filter_test";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        switch (result) {
          case (#ok(id)) {
            // Add multiple datapoints at different times
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 10.0, #manual("test"), 1000);
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 20.0, #manual("test"), 2000);
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 30.0, #manual("test"), 3000);

            // Get all
            let all = MetricModel.getDatapoints(datapoints, id, null);
            expect.nat(all.size()).equal(3);

            // Get since 2000
            let filtered = MetricModel.getDatapoints(datapoints, id, ?2000);
            expect.nat(filtered.size()).equal(2);

            // Get since 3000
            let latest = MetricModel.getDatapoints(datapoints, id, ?3000);
            expect.nat(latest.size()).equal(1);
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "getLatestDatapoint returns most recent datapoint",
      func() {
        let registry = MetricModel.emptyRegistry();
        let datapoints = MetricModel.emptyDatapoints();

        let input : MetricModel.MetricRegistrationInput = {
          name = "latest_test";
          description = "Test";
          unit = "count";
          retentionDays = 90;
        };

        let (result, _) = MetricModel.registerMetric(
          registry,
          0,
          input,
          testPrincipal,
          testTimestamp,
        );

        switch (result) {
          case (#ok(id)) {
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 10.0, #manual("test"), 1000);
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 99.0, #manual("test"), 5000);
            ignore MetricModel.recordDatapoint(datapoints, registry, id, 30.0, #manual("test"), 3000);

            let latest = MetricModel.getLatestDatapoint(datapoints, id);
            switch (latest) {
              case (?dp) {
                expect.int(dp.timestamp).equal(5000);
              };
              case (null) {
                expect.bool(false).equal(true);
              };
            };
          };
          case (#err(_)) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "getLatestDatapoint returns null for no datapoints",
      func() {
        let datapoints = MetricModel.emptyDatapoints();
        let latest = MetricModel.getLatestDatapoint(datapoints, 0);
        expect.bool(latest == null).equal(true);
      },
    );
  },
);
