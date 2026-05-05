import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createHmac } from "node:crypto";
import type { _SERVICE, TestCanisterService } from "../../setup.ts";
import {
  createBackendCanister,
  createTestCanister,
  freshBackendCanister,
  freshTestCanister,
  SLACK_SIGNING_SECRET,
  SLACK_TEST_TOKEN,
  TEST_API_KEY,
  testCanisterIdlFactory,
} from "../../setup.ts";
import { expectOk, expectSome } from "../../helpers.ts";
import { withCassette } from "../../lib/cassette.ts";

// ============================================
// Approval Flow – Integration Tests
//
// Tests the end-to-end approval gate introduced in 5.2.1.1:
//   - Slack Block Kit button payloads (approve_workflow / deny_workflow) are
//     routed correctly and return HTTP 200 immediately (fire-and-forget timer).
//   - HMAC signature verification applies to block_actions payloads.
//   - Approval codes in button values are validated by the handler (wrong code
//     or unauthorized user → ephemeral rejection via response_url).
//
// Sections:
//   1. block_actions routing — pure HTTP routing, no approval state needed.
//      These tests pass without cassettes.
//
//   2. full approval pipeline — requires cassette recording:
//         RECORD_CASSETTES=true bun test tests/control-plane-core/integration-tests/approval-flow.spec.ts
//      These tests exercise the message handler → #awaitingApproval turn
//      state transition and then validate approval/denial flows.
//      They are currently skipped until a method for seeding approval state
//      via the test canister is added (see PLAN.md §5.2 phase 2).
// ============================================

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const TEST_SIGNING_SECRET = SLACK_SIGNING_SECRET;
const TEST_TIMESTAMP = "1700000000";

function computeSlackSignature(
  secret: string,
  timestamp: string,
  body: string,
): string {
  const baseString = `v0:${timestamp}:${body}`;
  const hmac = createHmac("sha256", secret);
  hmac.update(baseString);
  return `v0=${hmac.digest("hex")}`;
}

async function sendSignedWebhook(
  actor: Actor<_SERVICE>,
  body: string,
  timestamp: string = TEST_TIMESTAMP,
  signature?: string,
) {
  const sig =
    signature ?? computeSlackSignature(TEST_SIGNING_SECRET, timestamp, body);
  return actor.http_request_update({
    method: "POST",
    url: "/webhook/slack",
    headers: [
      ["content-type", "application/json"],
      ["x-slack-signature", sig],
      ["x-slack-request-timestamp", timestamp],
    ],
    body: encoder.encode(body),
  });
}

function decodeBody(response: { body: Uint8Array | number[] }): string {
  return decoder.decode(new Uint8Array(response.body));
}

// ============================================
// Test Suite
// ============================================

describe("Approval Flow", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let controllerIdentity: ReturnType<
    typeof import("@dfinity/pic").generateRandomIdentity
  >;

  beforeAll(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
    controllerIdentity = testEnv.controllerIdentity;
  });

  beforeEach(async () => {
    actor = (await freshBackendCanister(pic, controllerIdentity)).actor;
    expectOk(
      await actor.storeOrgCriticalSecrets(
        { slackSigningSecret: null },
        TEST_SIGNING_SECRET,
      ),
    );
    // Align PocketIC clock so HMAC timestamp verification passes.
    const desiredTimeMs = (parseInt(TEST_TIMESTAMP) + 30) * 1000;
    const currentTimeMs = await pic.getTime();
    if (desiredTimeMs > currentTimeMs) {
      await pic.setTime(desiredTimeMs);
    }
    await pic.tick();
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  // ============================================
  // block_actions routing (no cassettes needed)
  // ============================================

  describe("block_actions routing", () => {
    it("should return 200 for approve_workflow button click with valid HMAC", async () => {
      // The approval code is 64 hex chars; the canister returns 200 immediately
      // and dispatches processing asynchronously via a zero-delay timer.
      const payload = JSON.stringify({
        type: "block_actions",
        user: { id: "U_REQUESTER" },
        message: { ts: "1700000010.000001" },
        channel: { id: "C_ADMIN" },
        actions: [
          {
            action_id: "approve_workflow",
            value: "a".repeat(64),
          },
        ],
        response_url: "",
      });
      const body = `payload=${encodeURIComponent(payload)}`;
      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("");
    });

    it("should return 200 for deny_workflow button click with valid HMAC", async () => {
      const payload = JSON.stringify({
        type: "block_actions",
        user: { id: "U_REQUESTER" },
        message: { ts: "1700000010.000001" },
        channel: { id: "C_ADMIN" },
        actions: [
          {
            action_id: "deny_workflow",
            value: "b".repeat(64),
          },
        ],
        response_url: "",
      });
      const body = `payload=${encodeURIComponent(payload)}`;
      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("");
    });

    it("should return 200 for an unrecognized action_id (ignored by handler)", async () => {
      const payload = JSON.stringify({
        type: "block_actions",
        user: { id: "U_CLICKER" },
        message: { ts: "1700000010.000002" },
        channel: { id: "C_ADMIN" },
        actions: [
          {
            action_id: "some_unrelated_action",
            value: "irrelevant",
          },
        ],
        response_url: "",
      });
      const body = `payload=${encodeURIComponent(payload)}`;
      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("");
    });

    it("should return 401 for a block_actions payload with invalid HMAC", async () => {
      const payload = JSON.stringify({
        type: "block_actions",
        user: { id: "U_CLICKER" },
        message: { ts: "1700000010.000001" },
        channel: { id: "C_ADMIN" },
        actions: [{ action_id: "approve_workflow", value: "c".repeat(64) }],
        response_url: "",
      });
      const body = `payload=${encodeURIComponent(payload)}`;
      const badSig = computeSlackSignature(
        "wrong-secret",
        TEST_TIMESTAMP,
        body,
      );
      const response = await sendSignedWebhook(
        actor,
        body,
        TEST_TIMESTAMP,
        badSig,
      );
      expect(response.status_code).toBe(401);
    });

    it("should return 400 for a payload= body with unparseable JSON", async () => {
      // parseEnvelope fails before signature verification — malformed payloads
      // return 400. Slack should not send garbage, so this is correct behaviour.
      const body = "payload=%ZZnot_valid_json";
      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(400);
    });
  });

  // ============================================
  // Full approval pipeline
  //
  // Tests 2-4 use a test canister with pre-seeded state — no cassettes required.
  // Test 1 (approval-request-generates-code) requires real credentials and a
  // cassette recording.
  // ============================================

  describe("full approval pipeline", () => {
    let testPic: PocketIc;
    let testActor: Actor<TestCanisterService>;
    let testCanisterId: Awaited<
      ReturnType<typeof freshTestCanister>
    >["canisterId"];

    beforeAll(async () => {
      testPic = (await createTestCanister()).pic;
    });

    beforeEach(async () => {
      const canister = await freshTestCanister(testPic);
      testActor = canister.actor;
      testCanisterId = canister.canisterId;
    });

    afterAll(async () => {
      await testPic.tearDown();
    });

    it(
      "approval-request-generates-code: turn should enter #awaitingApproval after workflow approval request",
      async () => {
        const cassetteName =
          "control-plane-core/integration-tests/approval-flow/approval-request-generates-code";

        // A deferred actor on the same canister is required for withCassette
        // (deferred calls allow PocketIC to handle HTTPS outcalls between send
        // and await). The regular testActor is used for state queries afterward.
        const deferredActor = testPic.createDeferredActor<TestCanisterService>(
          testCanisterIdlFactory,
          testCanisterId,
        );

        // The turn ID will be "0_0" (agent 0, first turn in a fresh canister).
        const { result } = await withCassette(
          testPic,
          cassetteName,
          () =>
            deferredActor.testMessageHandlerDispatch(
              {
                user: "U_OWNER",
                text: "Delete workspace with ID 1.",
                channel: "C_TEST",
                ts: "1700000001.000001",
                threadTs: [],
                isBotMessage: false,
                agentMetadata: [],
              },
              SLACK_TEST_TOKEN,
              TEST_API_KEY,
            ),
          { ticks: 5, maxRounds: 3 },
        );
        await result;

        expect(expectSome(await testActor.testGetTurnStatus("0_0"))).toBe(
          "awaitingApproval",
        );
      },
      { timeout: 60_000 },
    );

    it("approval-reject-wrong-code: sending wrong code should leave turn in #awaitingApproval", async () => {
      const { turnId } = await testActor.testSeedApprovalForTurn(
        "workspace_delete",
        "U_OWNER",
      );

      // Wrong code — not in testDispatchApprovalState; handler logs and returns early
      // without setting a resume timer. No tick needed.
      await testActor.testHandleBlockAction(
        "approve_workflow",
        "0".repeat(64),
        "U_OWNER",
        "",
      );

      expect(expectSome(await testActor.testGetTurnStatus(turnId))).toBe(
        "awaitingApproval",
      );
    });

    it("approval-reject-wrong-user: different Slack user cannot approve someone else's request", async () => {
      const { turnId, approvalCode } = await testActor.testSeedApprovalForTurn(
        "workspace_delete",
        "U_OWNER",
      );

      // U_OTHER is neither the requester nor a workspace admin — handler posts an
      // ephemeral rejection (skipped for responseUrl="") and returns without setting
      // a resume timer. No tick needed.
      await testActor.testHandleBlockAction(
        "approve_workflow",
        approvalCode,
        "U_OTHER",
        "",
      );

      expect(
        expectSome(await testActor.testGetApprovalStatus(approvalCode)),
      ).toBe("pending");
      expect(expectSome(await testActor.testGetTurnStatus(turnId))).toBe(
        "awaitingApproval",
      );
    });

    it("approval-accept-and-dispatch: correct user approving transitions turn to #awaitingWorkflow", async () => {
      const { turnId, approvalCode } = await testActor.testSeedApprovalForTurn(
        "workspace_delete",
        "U_OWNER",
      );

      // Full-pipeline call — approval is marked #used synchronously, then a zero-delay
      // timer fires resumeWithApproval which dispatches to the mock engine.
      await testActor.testHandleBlockActionFullPipeline(
        "approve_workflow",
        approvalCode,
        "U_OWNER",
        "",
        SLACK_TEST_TOKEN,
        TEST_API_KEY,
      );

      // Approval record is marked #used synchronously before postOutcome.
      expect(
        expectSome(await testActor.testGetApprovalStatus(approvalCode)),
      ).toBe("approved");

      // Advance rounds to let the zero-delay timer fire and the async resume
      // chain (resumeWithApproval → engine.execute → awaitingWorkflow) complete.
      for (let i = 0; i < 5; i++) {
        await testPic.tick();
      }

      expect(expectSome(await testActor.testGetTurnStatus(turnId))).toBe(
        "awaitingWorkflow",
      );
    });
  });
});
