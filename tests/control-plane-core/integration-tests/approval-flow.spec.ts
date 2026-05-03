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
import type { _SERVICE } from "../../setup.ts";
import {
  createBackendCanister,
  SLACK_SIGNING_SECRET,
  freshBackendCanister,
} from "../../setup.ts";
import { expectOk } from "../../helpers.ts";

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
  // Full approval pipeline (cassettes required)
  //
  // These tests exercise the complete approval gate:
  //   1. A message causes the admin agent to call a workflow requiring approval.
  //   2. The turn enters #awaitingApproval state.
  //   3. Approval / denial via text reply or Block Kit button is validated.
  //
  // To run these tests you need:
  //   - Real Slack / OpenRouter credentials in .env.test
  //   - RECORD_CASSETTES=true bun test <this-file> (first run)
  //   - After recording: bun test <this-file> (playback)
  //
  // Note: Verifying internal turn state (#awaitingApproval / #awaitingWorkflow)
  // requires a testSeedApprovalForTurn helper on the test canister that does not
  // yet exist. Until that helper is added these tests are skipped. See PLAN.md
  // §5.2 phase 2 for the implementation plan.
  // ============================================

  describe.skip("full approval pipeline (needs cassettes + test-canister seeding)", () => {
    it("approval-request-generates-code: turn should enter #awaitingApproval after workflow approval request", () => {
      // TODO: send testMessageHandlerDispatch with a message that triggers workflow approval,
      // then call testGetTurnStatus and assert "awaitingApproval".
      // Requires RECORD_CASSETTES=true on first run.
    });

    it("approval-reject-wrong-code: sending wrong code should leave turn in #awaitingApproval", () => {
      // TODO: seed a turn in #awaitingApproval state, then send a message with
      // "approve wrongcode" and assert the turn status is unchanged.
    });

    it("approval-reject-wrong-user: different Slack user cannot approve someone else's request", () => {
      // TODO: seed approval for U_OWNER, send approval as U_OTHER, assert #err.
    });

    it("approval-accept-and-dispatch: correct user approving transitions turn to #awaitingWorkflow", () => {
      // TODO: seed approval for U_OWNER, approve as U_OWNER, assert turn is #awaitingWorkflow.
    });
  });
});
