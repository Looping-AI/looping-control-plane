import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// CreateMetricHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { name, description, unit, retentionDays }
//   2. Validates fields (non-empty name, retention 30–1825, unique name)
//   3. Registers the metric in MetricsRegistryState via MetricModel.registerMetric
// ============================================

function parseResponse(json: string): {
  success: boolean;
  metricId?: number;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

describe("CreateMetricHandler", () => {
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
        await testCanister.testCreateMetricHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when required fields are missing", async () => {
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({ name: "Revenue" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for empty metric name", async () => {
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "",
          description: "Some metric",
          unit: "count",
          retentionDays: 30,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("cannot be empty");
    });

    it("should return error for retention days below minimum", async () => {
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "ShortRetention",
          description: "Metric with short retention",
          unit: "count",
          retentionDays: 10,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Retention days must be at least");
    });

    it("should return error for retention days above maximum", async () => {
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "LongRetention",
          description: "Metric with long retention",
          unit: "count",
          retentionDays: 10000,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Retention days cannot exceed");
    });

    it("should return error for duplicate metric name", async () => {
      await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Revenue",
          description: "Monthly revenue",
          unit: "USD",
          retentionDays: 365,
        }),
      );
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Revenue",
          description: "Monthly revenue again",
          unit: "USD",
          retentionDays: 365,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("already exists");
    });
  });

  describe("successful creation", () => {
    it("should create a metric with all required fields", async () => {
      const result = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Revenue",
          description: "Monthly revenue in USD",
          unit: "USD",
          retentionDays: 365,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricId).toBe(0);
      expect(response.message).toContain("Revenue");
    });

    it("should increment metric IDs", async () => {
      const result1 = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Metric1",
          description: "First metric",
          unit: "count",
          retentionDays: 30,
        }),
      );
      const result2 = await testCanister.testCreateMetricHandler(
        JSON.stringify({
          name: "Metric2",
          description: "Second metric",
          unit: "count",
          retentionDays: 30,
        }),
      );
      expect(parseResponse(result1).metricId).toBe(0);
      expect(parseResponse(result2).metricId).toBe(1);
    });
  });
});
