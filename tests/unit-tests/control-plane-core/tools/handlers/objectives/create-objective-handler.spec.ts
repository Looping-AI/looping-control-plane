import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// CreateObjectiveHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for objective creation fields
//   2. Initializes value stream objectives state if not present
//   3. Calls ObjectiveModel.addObjective
//   4. Returns { success: true, objectiveId: N }
// ============================================

function parseResponse(json: string): {
  success: boolean;
  objectiveId?: number;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const DEFAULT_VS_ID = 0;

async function createObjective(
  testCanister: Actor<TestCanisterService>,
  params: {
    valueStreamId?: number;
    name?: string;
    objectiveType?: string;
    metricIds?: number[];
    computation?: string;
    targetType?: string;
    targetValue?: number;
    description?: string;
  } = {},
): Promise<number> {
  const args = JSON.stringify({
    valueStreamId: params.valueStreamId ?? DEFAULT_VS_ID,
    name: params.name ?? "Test Objective",
    objectiveType: params.objectiveType ?? "target",
    metricIds: params.metricIds ?? [0],
    computation: params.computation ?? "avg(metrics)",
    targetType: params.targetType ?? "percentage",
    targetValue: params.targetValue ?? 80.0,
    ...(params.description !== undefined
      ? { description: params.description }
      : {}),
  });
  const result = await testCanister.testCreateObjectiveHandler(args);
  return parseResponse(result).objectiveId as number;
}

describe("CreateObjectiveHandler", () => {
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
        await testCanister.testCreateObjectiveHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when name is missing", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when targetType is missing", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Test Objective",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
    });

    it("should return error for empty name", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("name");
    });

    it("should return error for empty computation", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Test",
          objectiveType: "target",
          metricIds: [0],
          computation: "",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("computation");
    });
  });

  describe("objective creation", () => {
    it("should create an objective and return objectiveId 0 for the first one", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Test Objective",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.objectiveId).toBe(0);
    });

    it("should increment objective IDs", async () => {
      const id1 = await createObjective(testCanister, { name: "Objective 1" });
      const id2 = await createObjective(testCanister, { name: "Objective 2" });
      expect(id1).toBe(0);
      expect(id2).toBe(1);
    });

    it("should support percentage target type", async () => {
      const id = await createObjective(testCanister, {
        targetType: "percentage",
        targetValue: 95.0,
      });
      expect(id).toBe(0);
    });

    it("should support count target type with increase direction", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Count Up",
          objectiveType: "contributing",
          metricIds: [0],
          computation: "count(events)",
          targetType: "count",
          targetValue: 100.0,
          targetDirection: "increase",
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should support count target type with decrease direction", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Count Down",
          objectiveType: "guardrail",
          metricIds: [0],
          computation: "count(errors)",
          targetType: "count",
          targetValue: 50.0,
          targetDirection: "decrease",
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should support threshold target type", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "In Range",
          objectiveType: "guardrail",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "threshold",
          targetValue: 10.0,
          targetMax: 100.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should support boolean target type", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Feature Done",
          objectiveType: "prerequisite",
          metricIds: [0],
          computation: "binary(done)",
          targetType: "boolean",
          targetBoolean: true,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow objective without description", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "No Desc",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow objective with description", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "With Desc",
          description: "A detailed description",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow objective with targetDate", async () => {
      const result = await testCanister.testCreateObjectiveHandler(
        JSON.stringify({
          valueStreamId: DEFAULT_VS_ID,
          name: "Date Objective",
          objectiveType: "target",
          metricIds: [0],
          computation: "avg(metrics)",
          targetType: "percentage",
          targetValue: 80.0,
          targetDate: Date.now() * 1_000_000 + 86400_000_000_000,
        }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should create objectives for different value stream IDs independently", async () => {
      const id0 = await createObjective(testCanister, {
        valueStreamId: 0,
        name: "VS 0 Obj",
      });
      const id1 = await createObjective(testCanister, {
        valueStreamId: 1,
        name: "VS 1 Obj",
      });
      // Each VS starts at ID 0
      expect(id0).toBe(0);
      expect(id1).toBe(0);
    });
  });
});
