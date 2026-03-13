import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// RecordMetricDatapointHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId, value, sourceType?, sourceLabel? }
//   2. Records a datapoint via MetricModel.recordDatapoint
//   3. Returns error if metric does not exist or required fields missing
// ============================================

function parseResponse(json: string): {
  success: boolean;
  metricId?: number;
  action?: string;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

async function createMetric(
  testCanister: Actor<TestCanisterService>,
  name = "Revenue",
): Promise<number> {
  const result = await testCanister.testCreateMetricHandler(
    JSON.stringify({
      name,
      description: "Monthly revenue in USD",
      unit: "USD",
      retentionDays: 365,
    }),
  );
  return JSON.parse(result).metricId as number;
}

describe("RecordMetricDatapointHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testRecordMetricDatapointHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when required fields are missing", async () => {
      const result = await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });
  });

  describe("datapoint recording", () => {
    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: 999, value: 100.0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Metric not found");
    });

    it("should record a datapoint for an existing metric", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 1000.5 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(id);
      expect(response.action).toBe("datapoint_recorded");
    });

    it("should record a datapoint with custom sourceType and sourceLabel", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({
          metricId: id,
          value: 42.0,
          sourceType: "integration",
          sourceLabel: "stripe-api",
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should default sourceType to manual when not provided", async () => {
      const id = await createMetric(testCanister);
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 50.0 }),
      );
      // Verify via get-metric-datapoints that the datapoint exists
      const dpResult = JSON.parse(
        await testCanister.testGetMetricDatapointsHandler(
          JSON.stringify({ metricId: id }),
        ),
      );
      expect(dpResult.count).toBe(1);
      expect(dpResult.datapoints[0].source).toContain("manual");
    });
  });
});
