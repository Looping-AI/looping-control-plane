import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DeleteMetricHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId }
//   2. Unregisters the metric and purges all its datapoints
//   3. Returns error if metric does not exist
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

describe("DeleteMetricHandler", () => {
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
      const result = await testCanister.testDeleteMetricHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: metricId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testDeleteMetricHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("metric deletion", () => {
    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testDeleteMetricHandler(
        JSON.stringify({ metricId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Metric not found");
    });

    it("should delete an existing metric", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testDeleteMetricHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(id);
      expect(response.action).toBe("metric_deleted");
    });

    it("should make the metric unretrievable after deletion", async () => {
      const id = await createMetric(testCanister);
      await testCanister.testDeleteMetricHandler(
        JSON.stringify({ metricId: id }),
      );
      const getResult = await testCanister.testGetMetricHandler(
        JSON.stringify({ metricId: id }),
      );
      expect(JSON.parse(getResult).success).toBe(false);
    });

    it("should purge metric datapoints on deletion", async () => {
      const id = await createMetric(testCanister);
      // Record some datapoints
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 100.0 }),
      );
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 200.0 }),
      );
      // Verify datapoints exist
      const dpBefore = JSON.parse(
        await testCanister.testGetMetricDatapointsHandler(
          JSON.stringify({ metricId: id }),
        ),
      );
      expect(dpBefore.count).toBe(2);
      // Delete the metric
      await testCanister.testDeleteMetricHandler(
        JSON.stringify({ metricId: id }),
      );
      // Datapoints should be gone (metric not found error)
      const dpAfter = JSON.parse(
        await testCanister.testGetMetricDatapointsHandler(
          JSON.stringify({ metricId: id }),
        ),
      );
      expect(dpAfter.success).toBe(false);
    });
  });
});
