import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetMetricHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { metricId }
//   2. Returns the full metric definition or an error if not found
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  description?: string;
  unit?: string;
  retentionDays?: number;
  error?: string;
} {
  return JSON.parse(json);
}

describe("GetMetricHandler", () => {
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
      const result = await testCanister.testGetMetricHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: metricId");
    });

    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testGetMetricHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("metric lookup", () => {
    it("should return error for non-existent metric", async () => {
      const result = await testCanister.testGetMetricHandler(
        JSON.stringify({ metricId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Metric not found");
    });

    it("should return a registered metric by ID", async () => {
      const createResult = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Revenue",
          description: "Monthly revenue in USD",
          unit: "USD",
          retentionDays: 365,
        }),
      );
      const metricId = JSON.parse(createResult).metricId as number;

      const result = await testCanister.testGetMetricHandler(
        JSON.stringify({ metricId }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(metricId);
      expect(response.name).toBe("Revenue");
      expect(response.description).toBe("Monthly revenue in USD");
      expect(response.unit).toBe("USD");
      expect(response.retentionDays).toBe(365);
    });
  });
});
