import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// UpdateObjectiveHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId, ...optional fields }
//   2. Updates the objective fields provided
//   3. Returns { success: true, message } or error
// ============================================

function parseResponse(json: string): {
  success: boolean;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

async function createObjective(
  testCanister: Actor<TestCanisterService>,
  name = "Test Objective",
  valueStreamId = 0,
): Promise<number> {
  const result = await testCanister.testCreateObjectiveHandler(
    JSON.stringify({
      valueStreamId,
      name,
      description: "Original description",
      objectiveType: "target",
      metricIds: [0],
      computation: "avg(metrics)",
      targetType: "percentage",
      targetValue: 80.0,
    }),
  );
  return JSON.parse(result).objectiveId as number;
}

async function getObjective(
  testCanister: Actor<TestCanisterService>,
  objectiveId: number,
  valueStreamId = 0,
) {
  const result = await testCanister.testGetObjectiveHandler(
    JSON.stringify({ valueStreamId, objectiveId }),
  );
  return JSON.parse(result);
}

describe("UpdateObjectiveHandler", () => {
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
      const result = await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({ objectiveId: 0, name: "New Name" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, name: "New Name" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999, name: "New" }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("field updates", () => {
    it("should update objective name", async () => {
      const id = await createObjective(testCanister);

      const updateResult = await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id, name: "New Name" }),
      );
      expect(parseResponse(updateResult).success).toBe(true);

      const obj = await getObjective(testCanister, id);
      expect(obj.name).toBe("New Name");
    });

    it("should update objective description", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          description: "Updated description",
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.description).toBe("Updated description");
    });

    it("should clear description with clearDescription flag", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          clearDescription: true,
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.description).toBeNull();
    });

    it("should update objective status to paused", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          status: "paused",
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.status).toBe("paused");
    });

    it("should update objective target", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          targetType: "count",
          targetValue: 50.0,
          targetDirection: "decrease",
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.target.type).toBe("count");
      expect(obj.target.value).toBe(50.0);
      expect(obj.target.direction).toBe("decrease");
    });

    it("should update objective type", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          objectiveType: "guardrail",
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.objectiveType).toBe("guardrail");
    });

    it("should keep unchanged fields when updating only one", async () => {
      const id = await createObjective(testCanister, "Original Name");

      await testCanister.testUpdateObjectiveHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          status: "paused",
        }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.name).toBe("Original Name");
      expect(obj.status).toBe("paused");
    });
  });
});
