import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetLatestMetricDatapointHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId }
//   2. Returns the most recently recorded datapoint (highest timestamp)
//   3. Returns null datapoint field when none exist
//   4. Returns error if metric does not exist
// ============================================

function parseResponse(json: string): {
  success: boolean;
  metricId?: number;
  metricName?: string;
  timestamp?: number;
  value?: number;
  source?: string;
  datapoint?: null;
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

describe("GetLatestMetricDatapointHandler", () => {
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
      const result = await testCanister.testGetLatestMetricDatapointHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: metricId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testGetLatestMetricDatapointHandler(
          "not-valid-json",
        );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("latest datapoint retrieval", () => {
    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testGetLatestMetricDatapointHandler(
        JSON.stringify({ metricId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Metric not found");
    });

    it("should return null datapoint when no datapoints exist", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testGetLatestMetricDatapointHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(id);
      expect(response.datapoint).toBeNull();
    });

    it("should return the latest datapoint after recording", async () => {
      const id = await createMetric(testCanister);
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 100.0 }),
      );
      await testCanister.testRecordMetricDatapointHandler(
        JSON.stringify({ metricId: id, value: 300.0 }),
      );

      const result = await testCanister.testGetLatestMetricDatapointHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(id);
      expect(response.metricName).toBe("Revenue");
      // The latest datapoint should have a value (300.0 was recorded last)
      expect(response.value).toBe(300.0);
    });
  });
});
