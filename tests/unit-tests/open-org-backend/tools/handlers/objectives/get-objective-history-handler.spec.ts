import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetObjectiveHistoryHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId }
//   2. Returns the datapoint history in chronological order
//   3. Returns { success, objectiveId, count, history[] }
// ============================================

function parseHistoryResponse(json: string): {
  success: boolean;
  objectiveId?: number;
  count?: number;
  history?: Array<{
    timestamp: number;
    value: number | null;
    valueWarning: string | null;
    commentCount: number;
    comments: Array<{ timestamp: number; author: string; message: string }>;
  }>;
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

async function recordDatapoint(
  testCanister: Actor<TestCanisterService>,
  objectiveId: number,
  value: number,
  valueStreamId = 0,
): Promise<void> {
  await testCanister.testRecordObjectiveDatapointHandler(
    JSON.stringify({ valueStreamId, objectiveId, value }),
  );
}

describe("GetObjectiveHistoryHandler", () => {
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
      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ objectiveId: 0 }),
      );
      const response = parseHistoryResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseHistoryResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999 }),
      );
      const response = parseHistoryResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("history retrieval", () => {
    it("should return empty history for a new objective", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(0);
      expect(response.history).toEqual([]);
    });

    it("should return history in chronological order", async () => {
      const id = await createObjective(testCanister);

      await recordDatapoint(testCanister, id, 60.0);
      await recordDatapoint(testCanister, id, 70.0);
      await recordDatapoint(testCanister, id, 80.0);

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(3);
      const values = response.history!.map((h) => h.value);
      expect(values).toEqual([60.0, 70.0, 80.0]);
    });

    it("should include valueWarning in history entry", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          value: 50.0,
          valueWarning: "Data quality issue",
        }),
      );

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.history![0].valueWarning).toBe("Data quality issue");
    });

    it("should include null valueWarning when not set", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.history![0].valueWarning).toBeNull();
    });

    it("should reflect objectiveId in the response", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.objectiveId).toBe(id);
    });

    it("should include comments on history entries", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          value: 75.0,
          comment: "Good result",
          commentAuthor: "analyst",
        }),
      );

      const result = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseHistoryResponse(result);
      expect(response.history![0].commentCount).toBe(1);
      expect(response.history![0].comments[0].message).toBe("Good result");
    });
  });
});
