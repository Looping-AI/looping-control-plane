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
// WorkflowEngineHandler Unit Tests
//
// This handler:
//   1. Parses JSON args (workflow-specific parameters — no workflowId field)
//   2. Processes coreDirectives (approval / preValidation) — none in test descriptor
//   3. Issues a WorkflowToken via WorkflowEnvelopeModel
//   4. Builds an EnvelopePayload and dispatches to the engine
//   5. Returns {"dispatched":true} on success (#ok)
//   6. Returns {"type":"camelCase","message":"..."} on failure (#err)
//
// The test canister wraps WorkflowEngineHandler.handle with a minimal
// org-admin AgentRecord stub and a descriptor with no coreDirectives.
// mockDispatchFail=false → engine #ok, true → engine call throws (#err)
//
// testWorkflowEngineHandler(args, botToken, mockDispatchFail)
//   botToken: [] = null, ["xoxb-token"] = present (unused by empty-directive descriptor)
// ============================================

function parseSuccess(json: string): { dispatched: boolean } {
  return JSON.parse(json);
}

function parseError(json: string): { type: string; message: string } {
  return JSON.parse(json);
}

function parseApprovalPrompt(json: string): {
  dispatched: boolean;
  approvalRequired: boolean;
  approvalCode: string;
} {
  return JSON.parse(json);
}

const NO_TOKEN = [] as [] | [string];

const DISPATCH_OK = false; // mockDispatchFail = false → engine #ok
const DISPATCH_FAIL = true; // mockDispatchFail = true → engine call throws

const NO_SLACK_CHANNEL = [] as [] | [string];
const NO_PRE_APPROVE = false;
const PRE_APPROVE = true;

const ANY_VALID_ARGS = JSON.stringify({});

describe("WorkflowEngineHandler", () => {
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
    it("returns a parseError when args is not valid JSON", async () => {
      const result = await testCanister.testWorkflowEngineHandler(
        "not-valid-json",
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseError(result);
      expect(response.type).toBe("parseError");
      expect(response.message).toContain("Invalid JSON arguments");
      expect(response.message).toContain("admin-v1");
    });
  });

  describe("dispatch success path", () => {
    it("returns dispatched:true when the engine accepts the envelope", async () => {
      const result = await testCanister.testWorkflowEngineHandler(
        ANY_VALID_ARGS,
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseSuccess(result);
      expect(response.dispatched).toBe(true);
    });

    it("accepts workflow-specific args fields without treating them as errors", async () => {
      const argsWithFields = JSON.stringify({
        targetChannel: "C_TEST",
        dryRun: true,
      });
      const result = await testCanister.testWorkflowEngineHandler(
        argsWithFields,
        NO_TOKEN,
        DISPATCH_OK,
      );
      const response = parseSuccess(result);
      expect(response.dispatched).toBe(true);
    });
  });

  describe("dispatch failure path", () => {
    it("returns a structured dispatchFailed error when the engine rejects", async () => {
      const result = await testCanister.testWorkflowEngineHandler(
        ANY_VALID_ARGS,
        NO_TOKEN,
        DISPATCH_FAIL,
      );
      const response = parseError(result);
      expect(response.type).toBe("dispatchFailed");
      expect(typeof response.message).toBe("string");
      expect(response.message.length).toBeGreaterThan(0);
    });
  });

  describe("approval directive (#require('approval'))", () => {
    it("returns approvalRequired:true with a non-empty code when no approvalCode is present", async () => {
      const result = await testCanister.testWorkflowEngineHandlerApproval(
        JSON.stringify({}),
        NO_TOKEN,
        DISPATCH_OK,
        NO_PRE_APPROVE,
        NO_SLACK_CHANNEL,
      );
      const response = parseApprovalPrompt(result);
      expect(response.dispatched).toBe(false);
      expect(response.approvalRequired).toBe(true);
      expect(typeof response.approvalCode).toBe("string");
      expect(response.approvalCode.length).toBeGreaterThan(0);
    });

    it("proceeds to dispatch when a valid pre-validated approval code is injected", async () => {
      const result = await testCanister.testWorkflowEngineHandlerApproval(
        JSON.stringify({}),
        NO_TOKEN,
        DISPATCH_OK,
        PRE_APPROVE,
        NO_SLACK_CHANNEL,
      );
      const response = parseSuccess(result);
      expect(response.dispatched).toBe(true);
    });
  });
});
