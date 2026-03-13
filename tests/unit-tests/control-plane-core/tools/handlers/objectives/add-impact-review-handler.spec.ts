import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// AddImpactReviewHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId, objectiveId, perceivedImpact, comment?, author? }
//   2. Adds an impact review to the objective's history
//   3. Returns { success: true, message: "Impact review added successfully" } or error
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

async function getReviews(
  testCanister: Actor<TestCanisterService>,
  objectiveId: number,
  valueStreamId = 0,
) {
  const result = await testCanister.testGetImpactReviewsHandler(
    JSON.stringify({ valueStreamId, objectiveId }),
  );
  return JSON.parse(result) as {
    success: boolean;
    reviews: Array<{
      timestamp: number;
      perceivedImpact: string;
      comment: string | null;
      author: string;
    }>;
    count: number;
  };
}

describe("AddImpactReviewHandler", () => {
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
      const result = await testCanister.testAddImpactReviewHandler(
        JSON.stringify({ objectiveId: 0, perceivedImpact: "high" }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error when objectiveId is missing", async () => {
      const result = await testCanister.testAddImpactReviewHandler(
        JSON.stringify({ valueStreamId: 0, perceivedImpact: "high" }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error when perceivedImpact is missing", async () => {
      const result = await testCanister.testAddImpactReviewHandler(
        JSON.stringify({ valueStreamId: 0, objectiveId: 0 }),
      );
      expect(parseResponse(result).success).toBe(false);
      expect(parseResponse(result).error).toContain("Missing required fields");
    });

    it("should return error for invalid perceivedImpact value", async () => {
      const id = await createObjective(testCanister);
      const result = await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "extreme",
        }),
      );
      expect(parseResponse(result).success).toBe(false);
    });
  });

  describe("adding impact reviews", () => {
    it("should successfully add an impact review", async () => {
      const id = await createObjective(testCanister);

      const result = await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "high",
        }),
      );
      expect(parseResponse(result).success).toBe(true);
      expect(parseResponse(result).message).toContain("Impact review added");
    });

    it("should persist the review and be retrievable", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "medium",
          comment: "Moderate improvement seen",
        }),
      );

      const { success, count, reviews } = await getReviews(testCanister, id);
      expect(success).toBe(true);
      expect(count).toBe(1);
      expect(reviews[0].perceivedImpact).toBe("medium");
      expect(reviews[0].comment).toBe("Moderate improvement seen");
    });

    const validImpacts = [
      "negative",
      "none",
      "low",
      "medium",
      "high",
      "unclear",
    ] as const;

    for (const impact of validImpacts) {
      it(`should accept perceivedImpact = "${impact}"`, async () => {
        const id = await createObjective(testCanister);

        const result = await testCanister.testAddImpactReviewHandler(
          JSON.stringify({
            valueStreamId: 0,
            objectiveId: id,
            perceivedImpact: impact,
          }),
        );
        expect(parseResponse(result).success).toBe(true);

        const { reviews } = await getReviews(testCanister, id);
        expect(reviews[0].perceivedImpact).toBe(impact);
      });
    }

    it("should support adding a review without a comment", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "low",
        }),
      );

      const { reviews } = await getReviews(testCanister, id);
      expect(reviews[0].comment).toBeNull();
    });

    it("should use default author when not specified", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "none",
        }),
      );

      const { reviews } = await getReviews(testCanister, id);
      expect(reviews[0].author).toBeTruthy();
    });

    it("should use provided author when specified", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "high",
          author: "product-team",
        }),
      );

      const { reviews } = await getReviews(testCanister, id);
      expect(reviews[0].author).toBe("product-team");
    });

    it("should accumulate multiple reviews", async () => {
      const id = await createObjective(testCanister);

      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "low",
        }),
      );
      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "high",
        }),
      );
      await testCanister.testAddImpactReviewHandler(
        JSON.stringify({
          valueStreamId: 0,
          objectiveId: id,
          perceivedImpact: "medium",
        }),
      );

      const { count } = await getReviews(testCanister, id);
      expect(count).toBe(3);
    });
  });
});
