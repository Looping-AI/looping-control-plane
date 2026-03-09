import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// AddObjectiveDatapointCommentHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId, historyIndex, message, author? }
//   2. Adds a comment to a specific history data point
//   3. Returns { success: true, message: "Comment added successfully" } or error
// ============================================

function parseResponse(json: string): {
  success: boolean;
  error?: string;
  message?: string;
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

async function getHistory(
  testCanister: Actor<TestCanisterService>,
  objectiveId: number,
  valueStreamId = 0,
) {
  const result = await testCanister.testGetObjectiveHistoryHandler(
    JSON.stringify({ valueStreamId, objectiveId }),
  );
  return JSON.parse(result) as {
    history: Array<{
      commentCount: number;
      comments: Array<{ author: string; message: string }>;
    }>;
  };
}

describe("AddObjectiveDatapointCommentHandler", () => {
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
      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({ objectiveId: 0, historyIndex: 0, message: "comment" }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          historyIndex: 0,
          message: "comment",
        }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error when historyIndex is missing", async () => {
      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: 0,
          message: "comment",
        }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error when message is missing", async () => {
      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 0, historyIndex: 0 }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });
  });

  describe("error conditions", () => {
    it("should return error for invalid historyIndex (out of bounds)", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 99,
          message: "test",
        }),
      );
      expect(parseResponse(result).success).toBe(false);
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: 999,
          historyIndex: 0,
          message: "test",
        }),
      );
      expect(parseResponse(result).success).toBe(false);
    });
  });

  describe("adding comments", () => {
    it("should successfully add a comment to a history entry", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      const result = await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "Great progress!",
        }),
      );
      expect(parseResponse(result).success).toBe(true);
      expect(parseResponse(result).message).toContain("Comment added");
    });

    it("should persist the comment in history", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "Nice work!",
        }),
      );

      const history = await getHistory(testCanister, id);
      expect(history.history[0].commentCount).toBe(1);
      expect(history.history[0].comments[0].message).toBe("Nice work!");
    });

    it("should support multiple comments on the same history entry", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "First comment",
        }),
      );
      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "Second comment",
        }),
      );

      const history = await getHistory(testCanister, id);
      expect(history.history[0].commentCount).toBe(2);
    });

    it("should use default author when author is not specified", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "Default author comment",
        }),
      );

      const history = await getHistory(testCanister, id);
      const comment = history.history[0].comments[0];
      expect(comment.author).toBeTruthy();
    });

    it("should use provided author when specified", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 75.0);

      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 0,
          message: "Analyst comment",
          author: "data-analyst",
        }),
      );

      const history = await getHistory(testCanister, id);
      const comment = history.history[0].comments[0];
      expect(comment.author).toBe("data-analyst");
    });

    it("should add comments to the correct history entry", async () => {
      const id = await createObjective(testCanister);
      await recordDatapoint(testCanister, id, 60.0);
      await recordDatapoint(testCanister, id, 70.0);

      await testCanister.testAddObjectiveDatapointCommentHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          historyIndex: 1,
          message: "Only on second entry",
        }),
      );

      const history = await getHistory(testCanister, id);
      expect(history.history[0].commentCount).toBe(0);
      expect(history.history[1].commentCount).toBe(1);
    });
  });
});
