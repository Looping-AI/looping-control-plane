import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { createTestEnvironment, type _SERVICE } from "../../setup.ts";
import { expectErr, expectOk, expectSome, expectNone } from "../../helpers.ts";
import type {
  MetricRegistrationInput,
  MetricSource,
} from "../../builds/open-org-backend.did.d.ts";

describe("Metrics API", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerIdentity = testEnv.ownerIdentity;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("registerMetric", () => {
    it("should allow org owner to register a metric", async () => {
      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue in USD",
        unit: "USD",
        retentionDays: 365n,
      };

      const result = await actor.registerMetric(input);
      const metric = expectOk(result);

      expect(metric.id).toBe(0n);
      expect(metric.name).toBe("Revenue");
      expect(metric.description).toBe("Monthly revenue in USD");
      expect(metric.unit).toBe("USD");
      expect(metric.retentionDays).toBe(365n);
      expect(metric.createdBy).toEqual(ownerIdentity.getPrincipal());
    });

    it("should reject non-admin from registering a metric", async () => {
      actor.setIdentity(generateRandomIdentity());

      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };

      const result = await actor.registerMetric(input);
      expect(expectErr(result)).toContain("org owner");
    });

    it("should reject empty metric name", async () => {
      const input: MetricRegistrationInput = {
        name: "",
        description: "Some metric",
        unit: "count",
        retentionDays: 30n,
      };

      const result = await actor.registerMetric(input);
      expect(expectErr(result)).toBe("Metric name cannot be empty.");
    });

    it("should reject retention days below minimum", async () => {
      const input: MetricRegistrationInput = {
        name: "ShortRetention",
        description: "Metric with short retention",
        unit: "count",
        retentionDays: 10n, // Below minimum of 30
      };

      const result = await actor.registerMetric(input);
      expect(expectErr(result)).toContain("Retention days must be at least");
    });

    it("should reject retention days above maximum", async () => {
      const input: MetricRegistrationInput = {
        name: "LongRetention",
        description: "Metric with long retention",
        unit: "count",
        retentionDays: 10000n, // Above maximum of 1825
      };

      const result = await actor.registerMetric(input);
      expect(expectErr(result)).toContain("Retention days cannot exceed");
    });

    it("should reject duplicate metric name", async () => {
      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };

      // First registration should succeed
      const result1 = await actor.registerMetric(input);
      expectOk(result1);

      // Second registration with same name should fail
      const result2 = await actor.registerMetric(input);
      expect(expectErr(result2)).toBe(
        "A metric with this name already exists.",
      );
    });

    it("should increment metric IDs", async () => {
      const input1: MetricRegistrationInput = {
        name: "Metric1",
        description: "First metric",
        unit: "count",
        retentionDays: 30n,
      };

      const input2: MetricRegistrationInput = {
        name: "Metric2",
        description: "Second metric",
        unit: "count",
        retentionDays: 30n,
      };

      const result1 = await actor.registerMetric(input1);
      const result2 = await actor.registerMetric(input2);

      expect(expectOk(result1).id).toBe(0n);
      expect(expectOk(result2).id).toBe(1n);
    });
  });

  describe("getMetric", () => {
    it("should return a registered metric", async () => {
      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };

      const registerResult = await actor.registerMetric(input);
      const registeredMetric = expectOk(registerResult);

      const getResult = await actor.getMetric(registeredMetric.id);
      const metric = expectOk(getResult);

      expect(metric.id).toBe(registeredMetric.id);
      expect(metric.name).toBe("Revenue");
    });

    it("should return error for non-existent metric", async () => {
      const result = await actor.getMetric(999n);
      expect(expectErr(result)).toBe("Metric not found.");
    });

    it("should reject non-admin from getting a metric", async () => {
      // Register a metric as owner
      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(input);
      const metric = expectOk(registerResult);

      // Switch to non-admin
      actor.setIdentity(generateRandomIdentity());

      const result = await actor.getMetric(metric.id);
      expect(expectErr(result)).toContain("org owner");
    });
  });

  describe("listMetrics", () => {
    it("should return empty array when no metrics registered", async () => {
      const result = await actor.listMetrics();
      expect(expectOk(result)).toEqual([]);
    });

    it("should return all registered metrics", async () => {
      const input1: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };

      const input2: MetricRegistrationInput = {
        name: "Users",
        description: "Active users",
        unit: "count",
        retentionDays: 90n,
      };

      await actor.registerMetric(input1);
      await actor.registerMetric(input2);

      const result = await actor.listMetrics();
      const metrics = expectOk(result);

      expect(metrics.length).toBe(2);
      expect(metrics.map((m) => m.name).sort()).toEqual(["Revenue", "Users"]);
    });

    it("should reject non-admin from listing metrics", async () => {
      actor.setIdentity(generateRandomIdentity());

      const result = await actor.listMetrics();
      expect(expectErr(result)).toContain("org owner");
    });
  });

  describe("recordMetricDatapoint", () => {
    it("should record a datapoint for an existing metric", async () => {
      // First register a metric
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Record a datapoint
      const source: MetricSource = { manual: "admin" };
      const result = await actor.recordMetricDatapoint(
        metric.id,
        1000.5,
        source,
      );
      expectOk(result);
    });

    it("should reject recording datapoint for non-existent metric", async () => {
      const source: MetricSource = { manual: "admin" };
      const result = await actor.recordMetricDatapoint(999n, 100.0, source);
      expect(expectErr(result)).toBe("Metric not found.");
    });

    it("should reject non-admin from recording datapoints", async () => {
      // Register a metric as owner
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Switch to non-admin
      actor.setIdentity(generateRandomIdentity());

      const source: MetricSource = { manual: "user" };
      const result = await actor.recordMetricDatapoint(
        metric.id,
        100.0,
        source,
      );
      expect(expectErr(result)).toContain("org owner");
    });
  });

  describe("getMetricDatapoints", () => {
    it("should return empty array when no datapoints exist", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      const result = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(result)).toEqual([]);
    });

    it("should return recorded datapoints", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Record multiple datapoints
      const source: MetricSource = { manual: "admin" };
      await actor.recordMetricDatapoint(metric.id, 100.0, source);
      await actor.recordMetricDatapoint(metric.id, 200.0, source);
      await actor.recordMetricDatapoint(metric.id, 300.0, source);

      const result = await actor.getMetricDatapoints(metric.id, []);
      const datapoints = expectOk(result);

      expect(datapoints.length).toBe(3);
      expect(datapoints.map((d) => d.value)).toEqual([100.0, 200.0, 300.0]);
    });

    it("should return error for non-existent metric", async () => {
      const result = await actor.getMetricDatapoints(999n, []);
      expect(expectErr(result)).toBe("Metric not found.");
    });
  });

  describe("getLatestMetricDatapoint", () => {
    it("should return null when no datapoints exist", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      const result = await actor.getLatestMetricDatapoint(metric.id);
      const datapoint = expectOk(result);
      expectNone(datapoint);
    });

    it("should return the latest datapoint", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Record multiple datapoints
      const source: MetricSource = { manual: "admin" };
      await actor.recordMetricDatapoint(metric.id, 100.0, source);
      await actor.recordMetricDatapoint(metric.id, 200.0, source);
      await actor.recordMetricDatapoint(metric.id, 300.0, source);

      const result = await actor.getLatestMetricDatapoint(metric.id);
      const datapoint = expectSome(expectOk(result));

      // The latest should have the highest timestamp (which is the last one recorded: 300.0)
      expect(datapoint.value).toBe(300.0);
    });

    it("should return error for non-existent metric", async () => {
      const result = await actor.getLatestMetricDatapoint(999n);
      expect(expectErr(result)).toBe("Metric not found.");
    });
  });

  describe("unregisterMetric", () => {
    it("should remove a registered metric", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Verify it exists
      const getResult1 = await actor.getMetric(metric.id);
      expectOk(getResult1);

      // Unregister
      const unregisterResult = await actor.unregisterMetric(metric.id);
      expectOk(unregisterResult);

      // Verify it no longer exists
      const getResult2 = await actor.getMetric(metric.id);
      expect(expectErr(getResult2)).toBe("Metric not found.");
    });

    it("should also remove datapoints when unregistering", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Record some datapoints
      const source: MetricSource = { manual: "admin" };
      await actor.recordMetricDatapoint(metric.id, 100.0, source);
      await actor.recordMetricDatapoint(metric.id, 200.0, source);

      // Verify datapoints exist
      const dpResult1 = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(dpResult1).length).toBe(2);

      // Unregister metric
      await actor.unregisterMetric(metric.id);

      // Trying to get datapoints should fail (metric doesn't exist)
      const dpResult2 = await actor.getMetricDatapoints(metric.id, []);
      expect(expectErr(dpResult2)).toBe("Metric not found.");
    });

    it("should return error for non-existent metric", async () => {
      const result = await actor.unregisterMetric(999n);
      expect(expectErr(result)).toBe("Metric not found.");
    });

    it("should reject non-admin from unregistering", async () => {
      const metricInput: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(metricInput);
      const metric = expectOk(registerResult);

      // Switch to non-admin
      actor.setIdentity(generateRandomIdentity());

      const result = await actor.unregisterMetric(metric.id);
      expect(expectErr(result)).toContain("org owner");
    });
  });

  describe("org admin access", () => {
    it("should allow org admin to register metrics", async () => {
      // Add an org admin
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());

      // Switch to org admin
      actor.setIdentity(adminIdentity);

      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };

      const result = await actor.registerMetric(input);
      const metric = expectOk(result);

      expect(metric.name).toBe("Revenue");
      expect(metric.createdBy).toEqual(adminIdentity.getPrincipal());
    });

    it("should allow org admin to access all metric endpoints", async () => {
      // Register a metric as owner
      const input: MetricRegistrationInput = {
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365n,
      };
      const registerResult = await actor.registerMetric(input);
      const metric = expectOk(registerResult);

      // Add an org admin
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());

      // Switch to org admin
      actor.setIdentity(adminIdentity);

      // Org admin should be able to:
      // 1. Get metric
      const getResult = await actor.getMetric(metric.id);
      expectOk(getResult);

      // 2. List metrics
      const listResult = await actor.listMetrics();
      expectOk(listResult);

      // 3. Record datapoints
      const source: MetricSource = { manual: "admin" };
      const recordResult = await actor.recordMetricDatapoint(
        metric.id,
        500.0,
        source,
      );
      expectOk(recordResult);

      // 4. Get datapoints
      const dpResult = await actor.getMetricDatapoints(metric.id, []);
      expectOk(dpResult);

      // 5. Get latest datapoint
      const latestResult = await actor.getLatestMetricDatapoint(metric.id);
      expectOk(latestResult);

      // 6. Register new metric
      const newInput: MetricRegistrationInput = {
        name: "Users",
        description: "Active users",
        unit: "count",
        retentionDays: 90n,
      };
      const newResult = await actor.registerMetric(newInput);
      expectOk(newResult);

      // 7. Unregister metric
      const unregResult = await actor.unregisterMetric(metric.id);
      expectOk(unregResult);
    });
  });

  describe("purgeOldMetricDatapoints", () => {
    it("should allow org owner to purge old datapoints", async () => {
      // Register a metric
      const input: MetricRegistrationInput = {
        name: "TestMetric",
        description: "A test metric",
        unit: "count",
        retentionDays: 30n,
      };
      const regResult = await actor.registerMetric(input);
      expectOk(regResult);

      // Purge - returns 0 since no datapoints exist
      const purgeResult = await actor.purgeOldMetricDatapoints();
      const result = expectOk(purgeResult);
      expect(result.purged).toBe(0n);
    });

    it("should allow org admin to purge old datapoints", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());

      actor.setIdentity(adminIdentity);

      const purgeResult = await actor.purgeOldMetricDatapoints();
      expectOk(purgeResult);
    });

    it("should reject non-admin from purging datapoints", async () => {
      actor.setIdentity(generateRandomIdentity());

      const purgeResult = await actor.purgeOldMetricDatapoints();
      expect(expectErr(purgeResult)).toContain("org owner");
    });

    it("should return zero when no metrics registered", async () => {
      const purgeResult = await actor.purgeOldMetricDatapoints();
      const result = expectOk(purgeResult);
      expect(result.purged).toBe(0n);
    });

    it("should purge datapoints older than retention period", async () => {
      const thirtyOneDaysMs = 31 * 24 * 60 * 60 * 1000;

      // Register a metric with 30 day retention
      const input: MetricRegistrationInput = {
        name: "OldMetric",
        description: "A metric with old data",
        unit: "count",
        retentionDays: 30n,
      };
      const regResult = await actor.registerMetric(input);
      const metric = expectOk(regResult);

      // Record a datapoint
      const source: MetricSource = { manual: "test" };
      await actor.recordMetricDatapoint(metric.id, 100.0, source);

      // Verify datapoint exists
      const dpBefore = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(dpBefore).length).toBe(1);

      // Advance time past the retention period (31 days)
      await pic.advanceTime(thirtyOneDaysMs);

      // Purge should remove the old datapoint
      const purgeResult = await actor.purgeOldMetricDatapoints();
      const result = expectOk(purgeResult);
      expect(result.purged).toBe(1n);

      // Verify datapoint was removed
      const dpAfter = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(dpAfter).length).toBe(0);
    });

    it("should return zero when all datapoints are within retention period", async () => {
      // Register multiple metrics and add datapoints
      for (let i = 0; i < 3; i++) {
        const input: MetricRegistrationInput = {
          name: `Metric${i}`,
          description: `Test metric ${i}`,
          unit: "count",
          retentionDays: 30n,
        };
        const regResult = await actor.registerMetric(input);
        const metric = expectOk(regResult);

        // Record a fresh datapoint
        const source: MetricSource = { manual: "test" };
        await actor.recordMetricDatapoint(metric.id, 100.0, source);
      }

      // Purge should return 0 - all datapoints are fresh (within 30 days)
      const purgeResult = await actor.purgeOldMetricDatapoints();
      const result = expectOk(purgeResult);
      expect(result.purged).toBe(0n);
    });
  });
});
