import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetObjectiveHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId }
//   2. Returns the full objective or an error if not found
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  description?: string | null;
  objectiveType?: string;
  metricIds?: number[];
  computation?: string;
  target?: {
    type: string;
    value?: number;
    direction?: string;
    min?: number | null;
    max?: number | null;
  };
  targetDate?: number | null;
  current?: number | null;
  status?: string;
  createdAt?: number;
  updatedAt?: number;
  error?: string;
} {
  return JSON.parse(json);
}

async function createObjective(
  testCanister: Actor<TestCanisterService>,
  name: string,
  valueStreamId = 0,
): Promise<number> {
  const result = await testCanister.testCreateObjectiveHandler(
    JSON.stringify({
      valueStreamId,
      name,
      objectiveType: "target",
      metricIds: [0, 1],
      computation: "avg(metrics)",
      targetType: "percentage",
      targetValue: 80.0,
      description: "A test objective description",
    }),
  );
  return JSON.parse(result).objectiveId as number;
}

describe("GetObjectiveHandler", () => {
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
    it("should return error when valueStreamId is missing", async () => {
      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ objectiveId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testGetObjectiveHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("objective retrieval", () => {
    it("should return error for non-existent objective", async () => {
      // First initialize the VS state by creating one (so workspace is known)
      await createObjective(testCanister, "Existing Obj");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });

    it("should return error for non-existent value stream", async () => {
      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 999, objectiveId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });

    it("should return a created objective by ID", async () => {
      const id = await createObjective(testCanister, "Customer Conversion");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(id);
      expect(response.name).toBe("Customer Conversion");
      expect(response.objectiveType).toBe("target");
      expect(response.computation).toBe("avg(metrics)");
      expect(response.status).toBe("active");
    });

    it("should return description when set", async () => {
      const id = await createObjective(testCanister, "With Desc");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.description).toBe("A test objective description");
    });

    it("should return null description when not set", async () => {
      const objResult = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          name: "No Desc",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const id = JSON.parse(objResult).objectiveId as number;

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.description).toBeNull();
    });

    it("should return null current when no datapoints recorded", async () => {
      const id = await createObjective(testCanister, "No Data Obj");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.current).toBeNull();
    });

    it("should return the target object with type and value", async () => {
      const id = await createObjective(testCanister, "Target Obj");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.target).toBeDefined();
      expect(response.target!.type).toBe("percentage");
      expect(response.target!.value).toBe(80.0);
    });

    it("should return metricIds array", async () => {
      const id = await createObjective(testCanister, "Multi Metric");

      const result = await testCanister.testGetObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.metricIds).toEqual([0, 1]);
    });
  });
});
