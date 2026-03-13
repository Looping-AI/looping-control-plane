import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DeleteValueStreamHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { valueStreamId }
//   2. Deletes the value stream and its objectives
//   3. Returns error if value stream does not exist
// ============================================

function parseResponse(json: string): {
  success: boolean;
  valueStreamId?: number;
  action?: string;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

async function createValueStream(
  testCanister: Actor<TestCanisterService>,
  name = "Test Stream",
): Promise<number> {
  const result = await testCanister.testSaveValueStreamHandler(
    JSON.stringify({ name, problem: "A problem", goal: "A goal" }),
  );
  return JSON.parse(result).id as number;
}

describe("DeleteValueStreamHandler", () => {
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
      const result = await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({}),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: valueStreamId");
    });

    it("should return error for invalid JSON", async () => {
      const result =
        await testCanister.testDeleteValueStreamHandler("not-valid-json");
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });
  });

  describe("value stream deletion", () => {
    it("should return error for non-existent value stream", async () => {
      const result = await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: 999 }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Value stream not found");
    });

    it("should delete an existing value stream", async () => {
      const id = await createValueStream(testCanister);
      const result = await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.valueStreamId).toBe(id);
      expect(response.action).toBe("value_stream_deleted");
    });

    it("should make the value stream unretrievable after deletion", async () => {
      const id = await createValueStream(testCanister);
      await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const getResult = await testCanister.testGetValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      expect(JSON.parse(getResult).success).toBe(false);
    });

    it("should remove deleted value stream from list", async () => {
      const id0 = await createValueStream(testCanister, "Keep Me");
      const id1 = await createValueStream(testCanister, "Delete Me");

      await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: id1 }),
      );

      const listResult = await testCanister.testListValueStreamsHandler("{}");
      const list = JSON.parse(listResult);
      expect(list.count).toBe(1);
      expect(list.valueStreams[0].id).toBe(id0);
    });

    it("should return error when deleting an already-deleted value stream", async () => {
      const id = await createValueStream(testCanister);
      await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const result = await testCanister.testDeleteValueStreamHandler(
        JSON.stringify({ valueStreamId: id }),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Value stream not found");
    });
  });
});
