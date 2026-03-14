import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetValueStreamHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId }
//   2. Returns the full value stream details or an error if not found
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  problem?: string;
  goal?: string;
  status?: string;
  plan?: {
    summary: string;
    currentState: string;
    targetState: string;
    steps: string;
    risks: string;
    resources: string;
    createdAt: number;
    updatedAt: number;
  } | null;
  createdAt?: number;
  updatedAt?: number;
  error?: string;
} {
  return JSON.parse(json);
}

async function createValueStream(
  testCanister: Actor<TestCanisterService>,
  name: string,
  problem = "A problem",
  goal = "A goal",
): Promise<number> {
  const result = await testCanister.testSaveValueStreamHandler(
    JSON.stringify({ name, problem, goal }),
  );
  return JSON.parse(result).id as number;
}

describe("GetValueStreamHandler", () => {
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
      const result = await testCanister.testGetValueStreamHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: valueStreamId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testGetValueStreamHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("value stream lookup", () => {
    it("should return error for non-existent value stream", async () => {
      const result = await testCanister.testGetValueStreamHandler(
        JSON.stringify({ valueStreamId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Value stream not found");
    });

    it("should return a created value stream by ID", async () => {
      const id = await createValueStream(
        testCanister,
        "Customer Onboarding",
        "Slow onboarding",
        "Fast onboarding",
      );

      const result = await testCanister.testGetValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(id);
      expect(response.name).toBe("Customer Onboarding");
      expect(response.problem).toBe("Slow onboarding");
      expect(response.goal).toBe("Fast onboarding");
      expect(response.status).toBe("draft");
    });

    it("should return null plan when no plan exists", async () => {
      const id = await createValueStream(testCanister, "No Plan Stream");

      const result = await testCanister.testGetValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.plan).toBeNull();
    });

    it("should return plan details when a plan exists", async () => {
      const id = await createValueStream(testCanister, "Planned Stream");

      await testCanister.testSavePlanHandler(
        JSON.stringify({
          valueStreamId: id,
          summary: "Our approach",
          currentState: "Starting point",
          targetState: "End goal",
          steps: "Step 1, Step 2",
          risks: "Risk A",
          resources: "Resource X",
        }),
      );

      const result = await testCanister.testGetValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.plan).not.toBeNull();
      expect(response.plan!.summary).toBe("Our approach");
      expect(response.plan!.currentState).toBe("Starting point");
      expect(response.plan!.targetState).toBe("End goal");
    });
  });

  describe("increment IDs", () => {
    it("should assign sequential IDs to multiple value streams", async () => {
      const id0 = await createValueStream(testCanister, "First");
      const id1 = await createValueStream(testCanister, "Second");

      expect(id0).toBe(0);
      expect(id1).toBe(1);
    });
  });
});
