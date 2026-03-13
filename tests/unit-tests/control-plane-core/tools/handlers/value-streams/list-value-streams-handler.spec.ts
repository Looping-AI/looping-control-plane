import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ListValueStreamsHandler Unit Tests
//
// This handler:
//   1. Lists all value streams in workspace 0
//   2. Returns them as a JSON array with count and summary fields
// ============================================

function parseResponse(json: string): {
  success: boolean;
  count?: number;
  valueStreams?: Array<{
    id: number;
    name: string;
    problem: string;
    goal: string;
    status: string;
    hasPlan: boolean;
    createdAt: number;
    updatedAt: number;
  }>;
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

describe("ListValueStreamsHandler", () => {
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

  it("should return empty array when no value streams exist", async () => {
    const result = await testCanister.testListValueStreamsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.count).toBe(0);
    expect(response.valueStreams).toEqual([]);
  });

  it("should return all value streams in workspace", async () => {
    await createValueStream(
      testCanister,
      "Stream Alpha",
      "Problem A",
      "Goal A",
    );
    await createValueStream(testCanister, "Stream Beta", "Problem B", "Goal B");

    const result = await testCanister.testListValueStreamsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.count).toBe(2);
    expect(response.valueStreams).toHaveLength(2);
    const names = response.valueStreams!.map((vs) => vs.name).sort();
    expect(names).toEqual(["Stream Alpha", "Stream Beta"]);
  });

  it("should include status field for each value stream", async () => {
    await createValueStream(testCanister, "Draft Stream");

    const result = await testCanister.testListValueStreamsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.valueStreams![0].status).toBe("draft");
  });

  it("should reflect hasPlan=false before a plan is saved", async () => {
    await createValueStream(testCanister, "No Plan Yet");

    const result = await testCanister.testListValueStreamsHandler("{}");
    const response = parseResponse(result);
    expect(response.valueStreams![0].hasPlan).toBe(false);
  });

  it("should reflect hasPlan=true after a plan is saved", async () => {
    const id = await createValueStream(testCanister, "Planned Stream");

    await testCanister.testSavePlanHandler(
      JSON.stringify({
        valueStreamId: id,
        summary: "Plan summary",
        currentState: "Now",
        targetState: "Future",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      }),
    );

    const result = await testCanister.testListValueStreamsHandler("{}");
    const response = parseResponse(result);
    expect(response.valueStreams![0].hasPlan).toBe(true);
  });

  it("should reflect newly created value streams without caching", async () => {
    const before = parseResponse(
      await testCanister.testListValueStreamsHandler("{}"),
    );
    expect(before.count).toBe(0);

    await createValueStream(testCanister, "New Stream");

    const after = parseResponse(
      await testCanister.testListValueStreamsHandler("{}"),
    );
    expect(after.count).toBe(1);
    expect(after.valueStreams![0].name).toBe("New Stream");
  });
});
