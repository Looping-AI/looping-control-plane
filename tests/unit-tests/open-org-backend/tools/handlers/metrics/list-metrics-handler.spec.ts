import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ListMetricsHandler Unit Tests
//
// This handler:
//   1. Reads all registered metrics from MetricsRegistryState
//   2. Returns them as a JSON array with count
// ============================================

function parseResponse(json: string): {
  success: boolean;
  count?: number;
  metrics?: Array<{
    id: number;
    name: string;
    description: string;
    unit: string;
    retentionDays: number;
  }>;
  error?: string;
} {
  return JSON.parse(json);
}

describe("ListMetricsHandler", () => {
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

  it("should return empty array when no metrics registered", async () => {
    const result = await testCanister.testListMetricsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.count).toBe(0);
    expect(response.metrics).toEqual([]);
  });

  it("should return all registered metrics", async () => {
    await testCanister.testCreateMetricHandler(
      JSON.stringify({
        name: "Revenue",
        description: "Monthly revenue",
        unit: "USD",
        retentionDays: 365,
      }),
    );
    await testCanister.testCreateMetricHandler(
      JSON.stringify({
        name: "Users",
        description: "Active users",
        unit: "count",
        retentionDays: 90,
      }),
    );

    const result = await testCanister.testListMetricsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.count).toBe(2);
    expect(response.metrics).toHaveLength(2);
    const names = response.metrics!.map((m) => m.name).sort();
    expect(names).toEqual(["Revenue", "Users"]);
  });

  it("should reflect newly created metrics without caching", async () => {
    const before = parseResponse(
      await testCanister.testListMetricsHandler("{}"),
    );
    expect(before.count).toBe(0);

    await testCanister.testCreateMetricHandler(
      JSON.stringify({
        name: "Conversion",
        description: "Conversion rate",
        unit: "percent",
        retentionDays: 30,
      }),
    );

    const after = parseResponse(
      await testCanister.testListMetricsHandler("{}"),
    );
    expect(after.count).toBe(1);
    expect(after.metrics![0].name).toBe("Conversion");
  });
});
