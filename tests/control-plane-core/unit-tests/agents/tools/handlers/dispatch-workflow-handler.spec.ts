import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DispatchWorkflowHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { workflowId }
//   2. Issues an ExecutionToken via ExecutionTokenService
//   3. Builds an ExecutionEnvelope and dispatches to the engine
//   4. Returns { "dispatched": true } on success, { "dispatched": false, "error": "..." } on failure
//
// The test canister uses a minimal org-admin AgentRecord stub (id=0, ownedBy=0).
// dispatchToEngine is mocked: mockDispatchFail=false → #ok, true → #err("mock-engine-error").
//
// testDispatchWorkflowHandler(args, botToken, mockDispatchFail)
//   botToken: [] = no token (null), ["xoxb-token"] = bot token available
// ============================================

function parseResponse(json: string): {
  dispatched: boolean;
  error?: string;
} {
  return JSON.parse(json);
}

// Candid optional shorthands
const NO_TOKEN = [] as [] | [string];

const DISPATCH_OK = false; // mockDispatchFail = false → #ok
const DISPATCH_FAIL = true; // mockDispatchFail = true → #err

const VALID_ARGS = JSON.stringify({ workflowId: "admin-v1" });

describe("DispatchWorkflowHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeAll(async () => {
    pic = (await createTestCanister()).pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  describe("argument validation", () => {
    it("should return dispatched:false for invalid JSON", async () => {
      const result = await testCanister.testDispatchWorkflowHandler(
        "not-valid-json",
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseResponse(result);
      expect(response.dispatched).toBe(false);
      expect(response.error).toContain("Invalid JSON arguments");
    });

    it("should return dispatched:false when workflowId is missing", async () => {
      const result = await testCanister.testDispatchWorkflowHandler(
        JSON.stringify({}),
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseResponse(result);
      expect(response.dispatched).toBe(false);
      expect(response.error).toContain("workflowId");
    });

    it("should return dispatched:false when workflowId is not a string", async () => {
      const result = await testCanister.testDispatchWorkflowHandler(
        JSON.stringify({ workflowId: 42 }),
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseResponse(result);
      expect(response.dispatched).toBe(false);
      expect(response.error).toContain("workflowId");
    });
  });

  describe("dispatch success path", () => {
    it("should return dispatched:true when engine accepts the envelope", async () => {
      const result = await testCanister.testDispatchWorkflowHandler(
        VALID_ARGS,
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseResponse(result);
      expect(response.dispatched).toBe(true);
    });
  });

  describe("dispatch failure path", () => {
    it("should return dispatched:false when engine rejects the envelope", async () => {
      const result = await testCanister.testDispatchWorkflowHandler(
        VALID_ARGS,
        NO_TOKEN,
        DISPATCH_FAIL,
      );
      const response = parseResponse(result);
      expect(response.dispatched).toBe(false);
      expect(response.error).toBeDefined();
    });
  });
});
