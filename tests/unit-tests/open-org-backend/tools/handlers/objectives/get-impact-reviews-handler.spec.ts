import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetImpactReviewsHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId }
//   2. Returns all impact reviews for the objective
//   3. Returns { success, objectiveId, count, reviews[] }
// ============================================

function parseReviewsResponse(json: string): {
  success: boolean;
  objectiveId?: number;
  count?: number;
  reviews?: Array<{
    timestamp: number;
    perceivedImpact: string;
    comment: string | null;
    author: string;
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

async function addImpactReview(
  testCanister: Actor<TestCanisterService>,
  objectiveId: number,
  perceivedImpact: string,
  options: { comment?: string; author?: string; valueStreamId?: number } = {},
): Promise<void> {
  const { valueStreamId = 0, comment, author } = options;
  await testCanister.testAddImpactReviewHandler(
    JSON.stringify({
      valueStreamId,
      objectiveId,
      perceivedImpact,
      ...(comment !== undefined ? { comment } : {}),
      ...(author !== undefined ? { author } : {}),
    }),
  );
}

describe("GetImpactReviewsHandler", () => {
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
      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ objectiveId: 0 }),
      );
      const response = parseReviewsResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0 }),
      );
      const response = parseReviewsResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error for non-existent objective", async () => {
      await createObjective(testCanister); // ensure workspace exists
      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 999 }),
      );
      const response = parseReviewsResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("reviews retrieval", () => {
    it("should return empty reviews for a new objective", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(0);
      expect(response.reviews).toEqual([]);
    });

    it("should return the objectiveId in the response", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      expect(response.objectiveId).toBe(id);
    });

    it("should return all reviews after adding them", async () => {
      const id = await createObjective(testCanister);

      await addImpactReview(testCanister, id, "low");
      await addImpactReview(testCanister, id, "medium");
      await addImpactReview(testCanister, id, "high");

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      expect(response.success).toBe(true);
      expect(response.count).toBe(3);
    });

    it("should include all review fields", async () => {
      const id = await createObjective(testCanister);

      await addImpactReview(testCanister, id, "high", {
        comment: "Significant improvement",
        author: "reviewer-1",
      });

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      const review = response.reviews![0];
      expect(review.perceivedImpact).toBe("high");
      expect(review.comment).toBe("Significant improvement");
      expect(review.author).toBe("reviewer-1");
      expect(review.timestamp).toBeGreaterThan(0);
    });

    it("should return null comment when review has no comment", async () => {
      const id = await createObjective(testCanister);
      await addImpactReview(testCanister, id, "none");

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      expect(response.reviews![0].comment).toBeNull();
    });

    it("should preserve perceivedImpact values accurately", async () => {
      const id = await createObjective(testCanister);
      const impacts = [
        "negative",
        "none",
        "low",
        "medium",
        "high",
        "unclear",
      ] as const;

      for (const impact of impacts) {
        await addImpactReview(testCanister, id, impact);
      }

      const result = await testCanister.testGetImpactReviewsHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: id }),
      );
      const response = parseReviewsResponse(result);
      expect(response.count).toBe(impacts.length);
      const returnedImpacts = response.reviews!.map((r) => r.perceivedImpact);
      for (const impact of impacts) {
        expect(returnedImpacts).toContain(impact);
      }
    });
  });
});
