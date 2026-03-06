import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// UpdateMetricHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId, name?, description?, unit?, retentionDays? }
//   2. Applies partial update to an existing metric in MetricsRegistryState
// ============================================

function parseResponse(json: string): {
  success: boolean;
  metricId?: number;
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

describe("UpdateMetricHandler", () => {
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
    it("should return error for missing metricId", async () => {
      const result = await testCanister.testUpdateMetricHandler(
        JSON.stringify({ name: "NewName" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: metricId");
    });

    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testUpdateMetricHandler(
        JSON.stringify({ metricId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("successful updates", () => {
    it("should update the metric name", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testUpdateMetricHandler(
        JSON.stringify({ metricId: id, name: "Monthly Revenue" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(id);
    });

    it("should apply partial update (unit only)", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testUpdateMetricHandler(
        JSON.stringify({ metricId: id, unit: "EUR" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should succeed with only metricId (no-op update)", async () => {
      const id = await createMetric(testCanister);
      const result = await testCanister.testUpdateMetricHandler(
        JSON.stringify({ metricId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });
});
