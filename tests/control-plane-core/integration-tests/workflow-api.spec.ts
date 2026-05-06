import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { TestCanisterService } from "../../setup.ts";
import { createTestCanister, freshTestCanister } from "../../setup.ts";

// ============================================
// workflowApi – Candid endpoint tests
//
// Tests the `workflowApi` method on the main backend canister.
// This covers the transport-level authorization guard and verifies that
// the service layer is wired correctly (route dispatch, token lifecycle).
//
// No LLM calls are made — tokens are issued directly via testIssueWorkflowToken
// and the engine principal is set via testSetInternalEnginePrincipal (both
// controller-only helpers added for unit testing).
//
// The async effects scheduled by /workflow/complete and /workflow/milestone
// fire after the call returns. They fail silently here (no turn seeded in
// sessionStores), so only the synchronous response is verified. Phase 6
// covers the full async-effect end-to-end path.
// ============================================

describe("workflowApi – Candid endpoint", () => {
  let pic: PocketIc;
  let actor: Actor<TestCanisterService>;

  beforeAll(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    actor = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  // ============================================
  // Authorization guard
  // ============================================

  describe("authorization guard", () => {
    it("should pass guard and reach the service when no engine principal is configured", async () => {
      // Fresh canister — internalEnginePrincipal is null → guard is skipped
      // The call reaches the service layer, which rejects the bad token (not auth).
      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: "no-such-token" }),
      );
      // Service error (not auth) is still #err
      expect("err" in result).toBe(true);
      if ("err" in result) {
        expect(result.err).not.toContain("Unauthorized");
      }
    });

    it("should reject a caller that is not the registered engine principal", async () => {
      // Register a specific engine identity as the internal engine
      const engineIdentity = generateRandomIdentity();
      await actor.testSetInternalEnginePrincipal(engineIdentity.getPrincipal());

      // Switch to a different (non-engine) identity and call workflowApi
      const otherIdentity = generateRandomIdentity();
      actor.setIdentity(otherIdentity);

      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: "any" }),
      );
      expect("err" in result).toBe(true);
      if ("err" in result) {
        expect(result.err).toContain("Unauthorized");
      }
    });

    it("should allow the registered engine principal to call workflowApi", async () => {
      const engineIdentity = generateRandomIdentity();
      await actor.testSetInternalEnginePrincipal(engineIdentity.getPrincipal());

      // Issue a valid token so the service can proceed past token validation
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      // Switch to the engine identity
      actor.setIdentity(engineIdentity);

      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: nonce }),
      );
      // Guard passes; workspace 0 exists by default
      expect("ok" in result).toBe(true);
    });
  });

  // ============================================
  // GET /workspace
  // ============================================

  describe("GET /workspace", () => {
    it("should return workspace 0 for a valid full-scope token", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: nonce }),
      );

      expect("ok" in result).toBe(true);
      if ("ok" in result) {
        const data = JSON.parse(result.ok) as { id: number; name: string };
        expect(data.id).toBe(0);
        expect(typeof data.name).toBe("string");
      }
    });

    it("should return error for a missing envelopeNonce", async () => {
      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({}),
      );
      expect("err" in result).toBe(true);
    });

    it("should return error for an invalid token nonce", async () => {
      const result = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: "no-such-token" }),
      );
      expect("err" in result).toBe(true);
    });
  });

  // ============================================
  // POST /workflow/complete
  // ============================================

  describe("POST /workflow/complete", () => {
    it("should succeed and immediately revoke the token", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const firstResult = await actor.testWorkflowApi(
        { post: null },
        "/workflow/complete",
        JSON.stringify({
          envelopeNonce: nonce,
          humanSummary: "Workflow complete.",
          status: "completed",
        }),
      );
      expect("ok" in firstResult).toBe(true);

      // Token must be revoked after complete — second call should fail
      const retryResult = await actor.testWorkflowApi(
        { post: null },
        "/workflow/complete",
        JSON.stringify({
          envelopeNonce: nonce,
          humanSummary: "Retry.",
          status: "completed",
        }),
      );
      expect("err" in retryResult).toBe(true);
    });

    it("should return error for a missing humanSummary field", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const result = await actor.testWorkflowApi(
        { post: null },
        "/workflow/complete",
        JSON.stringify({ envelopeNonce: nonce }),
      );
      expect("err" in result).toBe(true);
    });
  });

  // ============================================
  // POST /workflow/milestone
  // ============================================

  describe("POST /workflow/milestone", () => {
    it("should succeed and leave the token valid (not revoked)", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const milestoneResult = await actor.testWorkflowApi(
        { post: null },
        "/workflow/milestone",
        JSON.stringify({
          envelopeNonce: nonce,
          humanSummary: "Step 1 done.",
        }),
      );
      expect("ok" in milestoneResult).toBe(true);

      // Token must still be valid after milestone (not revoked)
      const followUpResult = await actor.testWorkflowApi(
        { get: null },
        "/workspace",
        JSON.stringify({ envelopeNonce: nonce }),
      );
      expect("ok" in followUpResult).toBe(true);
    });

    it("should return error for a missing humanSummary field", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const result = await actor.testWorkflowApi(
        { post: null },
        "/workflow/milestone",
        JSON.stringify({ envelopeNonce: nonce }),
      );
      expect("err" in result).toBe(true);
    });
  });

  // ============================================
  // Unknown route
  // ============================================

  describe("unknown route", () => {
    it("should return error for an unrecognized path", async () => {
      const nonce = await actor.testIssueWorkflowToken("0_0", 0n);

      const result = await actor.testWorkflowApi(
        { get: null },
        "/no-such-route",
        JSON.stringify({ envelopeNonce: nonce }),
      );
      expect("err" in result).toBe(true);
    });
  });
});
