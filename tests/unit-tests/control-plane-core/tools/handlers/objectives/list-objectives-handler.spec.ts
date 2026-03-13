import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ListObjectivesHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId }
//   2. Initializes VS objectives state if not present (returns [] for unknown IDs)
//   3. Returns { success, valueStreamId, count, objectives[] }
// ============================================

function parseResponse(json: string): {
  success: boolean;
  valueStreamId?: number;
  count?: number;
  objectives?: Array<{
    id: number;
    name: string;
    objectiveType: string;
    status: string;
    computation: string;
  }>;
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
      metricIds: [0],
      computation: "avg(metrics)",
      targetType: "percentage",
      targetValue: 80.0,
    }),
  );
  return JSON.parse(result).objectiveId as number;
}

describe("ListObjectivesHandler", () => {
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
      const result = await testCanister.testListObjectivesHandler("{}");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: valueStreamId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testListObjectivesHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("listing objectives", () => {
    it("should return empty array for value stream with no objectives", async () => {
      const result = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(0);
      expect(response.objectives).toEqual([]);
    });

    it("should list all objectives for a value stream", async () => {
      await createObjective(testCanister, "Objective Alpha");
      await createObjective(testCanister, "Objective Beta");

      const result = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(2);
      expect(response.objectives).toHaveLength(2);
      const names = response.objectives!.map((o) => o.name).sort();
      expect(names).toEqual(["Objective Alpha", "Objective Beta"]);
    });

    it("should return only objectives for the requested value stream", async () => {
      await createObjective(testCanister, "VS0 Obj", 0);
      await createObjective(testCanister, "VS1 Obj", 1);

      const result0 = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const result1 = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 1 }),
      );

      const response0 = parseResponse(result0);
      const response1 = parseResponse(result1);

      expect(response0.count).toBe(1);
      expect(response0.objectives![0].name).toBe("VS0 Obj");
      expect(response1.count).toBe(1);
      expect(response1.objectives![0].name).toBe("VS1 Obj");
    });

    it("should include objectiveType and status in each objective", async () => {
      await createObjective(testCanister, "Test Obj");

      const result = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      const obj = response.objectives![0];
      expect(obj.objectiveType).toBe("target");
      expect(obj.status).toBe("active");
    });

    it("should reflect valueStreamId in the response", async () => {
      const result = await testCanister.testListObjectivesHandler(
        JSON.stringify({ valueStreamId: 42 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.valueStreamId).toBe(42);
    });
  });
});
