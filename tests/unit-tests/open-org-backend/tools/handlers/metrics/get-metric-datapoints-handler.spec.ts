import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetMetricDatapointsHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId, since?, limit? }
//   2. Returns all datapoints for the metric sorted by timestamp
//   3. Returns error if metric does not exist
// ============================================

function parseResponse(json: string): {
  success: boolean;
  metricId?: number;
  metricName?: string;
  unit?: string;
  count?: number;
  datapoints?: Array<{
    timestamp: number;
    value: number;
    source: string;
  }>;
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

describe("GetMetricDatapointsHandler", () => {
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
    it("should return error when metricId is missing", async () => {
      const result = await testCanister.testGetMetricDatapointsHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: metricId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testGetMetricDatapointsHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("datapoint retrieval", () => {
    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testGetMetricDatapointsHandler(
        JSON.stringify({ metricId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Metric not found");
    });

    it("should return empty array when no datapoints exist", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testGetMetricDatapointsHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(0);
      expect(response.datapoints).toEqual([]);
    });

    it("should return recorded datapoints", async () => {
      const id = await createMetric(testCanister);
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 100.0 }),
      );
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 200.0 }),
      );
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 300.0 }),
      );

      const result = await testCanister.testGetMetricDatapointsHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(3);
      expect(response.datapoints).toHaveLength(3);
    });

    it("should include metric name and unit in response", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testGetMetricDatapointsHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.metricName).toBe("Revenue");
      expect(response.unit).toBe("USD");
    });
  });
});
