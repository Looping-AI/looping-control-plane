import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ArchiveObjectiveHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId }
//   2. Sets the objective's status to #archived
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
  valueStreamId = 0,
): Promise<number> {
  const result = await testCanister.testCreateObjectiveHandler(
    JSON.stringify({
      valueStreamId,
      name: "Test Objective",
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

describe("ArchiveObjectiveHandler", () => {
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
      const result = await testCanister.testArchiveObjectiveHandler(
        JSON.stringify({ objectiveId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testArchiveObjectiveHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testArchiveObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("archiving", () => {
    it("should archive an objective, setting status to archived", async () => {
      const id = await createObjective(testCanister);

      const archiveResult = await testCanister.testArchiveObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      expect(parseResponse(archiveResult).success).toBe(true);

      const obj = await getObjective(testCanister, id);
      expect(obj.success).toBe(true);
      expect(obj.status).toBe("archived");
    });

    it("should only change status, keeping other fields intact", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testArchiveObjectiveHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );

      const obj = await getObjective(testCanister, id);
      expect(obj.name).toBe("Test Objective");
      expect(obj.computation).toBe("avg(metrics)");
      expect(obj.status).toBe("archived");
    });
  });
});
