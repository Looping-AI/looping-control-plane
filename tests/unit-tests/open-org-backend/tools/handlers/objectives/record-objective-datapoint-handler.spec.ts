import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// RecordObjectiveDatapointHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId, value, ... }
//   2. Records a datapoint (updates current + appends to history)
//   3. Returns { success: true, message, value } or error
// ============================================

function parseResponse(json: string): {
  success: boolean;
  value?: number;
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

describe("RecordObjectiveDatapointHandler", () => {
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
      const result = await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({ objectiveId: 0, value: 75.0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when value is missing", async () => {
      const result = await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999, value: 75.0 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("recording datapoints", () => {
    it("should record a datapoint and update current value", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id, value: 75.5 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.value).toBe(75.5);

      const obj = await getObjective(testCanister, id);
      expect(obj.current).toBe(75.5);
    });

    it("should record datapoint with value warning", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          value: 50.0,
          valueWarning: "Below target threshold",
        }),
      );

      const historyResult = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const history = JSON.parse(historyResult);
      expect(history.history[0].valueWarning).toBe("Below target threshold");
    });

    it("should record multiple datapoints and track history", async () => {
      const id = await createObjective(testCanister);

      for (let i = 0; i < 3; i++) {
        await testCanister.testRecordObjectiveDatapointHandler(
          JSON.stringify({
            valueStreamId: 0,
            objectiveId: id,
            value: 60.0 + i * 10,
          }),
        );
      }

      const obj = await getObjective(testCanister, id);
      expect(obj.current).toBe(80.0); // last recorded value

      const historyResult = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const history = JSON.parse(historyResult);
      expect(history.count).toBe(3);
    });

    it("should record datapoint with an inline comment", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testRecordObjectiveDatapointHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          value: 75.0,
          comment: "Good progress",
          commentAuthor: "analyst",
        }),
      );

      const historyResult = await testCanister.testGetObjectiveHistoryHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const history = JSON.parse(historyResult);
      expect(history.history[0].commentCount).toBe(1);
      expect(history.history[0].comments[0].message).toBe("Good progress");
    });
  });
});
