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
} from "../../../../setup";

// ============================================
// BlockActionsHandler Unit Tests
//
// Tests the approval-gate logic in block-actions-handler.mo:
//   - Approval records are only accepted from authorized users.
//   - approve_workflow transitions #pending → #used.
//   - deny_workflow transitions #pending → #expired.
//   - Already-processed records are silently ignored.
//   - Unknown codes are silently ignored.
//
// All tests use responseUrl="" to bypass the response_url HTTP call.
//
// IMPORTANT: pic.tick() is deliberately NOT called after testHandleBlockAction.
// The handler enqueues resumeWithApproval / resumeWithDenial in a zero-delay timer,
// but those resume paths require a live engine and secrets that are absent here.
// We only validate the synchronous approval-record state change, not the full
// engine dispatch path (tested separately in integration tests).
// ============================================

describe("BlockActionsHandler — approve_workflow / deny_workflow gate", () => {
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

  // ─── Unknown code ──────────────────────────────────────────────────────────

  it("should not crash when approve_workflow is sent with an unknown code", async () => {
    // No seed — the approval code does not exist in the state.
    // The handler logs a warning and posts an ephemeral error; it must not trap.
    await testCanister.testHandleBlockAction(
      "approve_workflow",
      "a".repeat(64),
      "U_OWNER",
      "", // responseUrl="" skips HTTP call
    );
    // No assertions on state — just verifying the call did not trap.
  });

  // ─── Already-processed record ──────────────────────────────────────────────

  it("should leave status as #used when approve_workflow is sent a second time", async () => {
    const code = await testCanister.testSeedApprovalRecord(
      "workspace_delete",
      "0_0",
      "U_OWNER",
    );

    // First click — transitions #pending → #used.
    await testCanister.testHandleBlockAction(
      "approve_workflow",
      code,
      "U_OWNER",
      "",
    );

    // Second click — handler sees #used (not #pending) and posts ephemeral "already processed".
    // Status must remain #used, not change to anything else.
    await testCanister.testHandleBlockAction(
      "approve_workflow",
      code,
      "U_OWNER",
      "",
    );

    const status = await testCanister.testGetApprovalStatus(code);
    expect(status).toEqual(["used"]);
  });

  // ─── Authorization ─────────────────────────────────────────────────────────

  it("should leave status as #pending when approve_workflow is sent by an unauthorized user", async () => {
    const code = await testCanister.testSeedApprovalRecord(
      "workspace_delete",
      "0_0",
      "U_OWNER",
    );

    // U_STRANGER is neither the original requester nor a workspace admin.
    await testCanister.testHandleBlockAction(
      "approve_workflow",
      code,
      "U_STRANGER",
      "",
    );

    const status = await testCanister.testGetApprovalStatus(code);
    expect(status).toEqual(["pending"]);
  });

  // ─── approve_workflow happy path ───────────────────────────────────────────

  it("should transition approval to #used when approve_workflow is sent by the original requester", async () => {
    const code = await testCanister.testSeedApprovalRecord(
      "workspace_delete",
      "0_0",
      "U_OWNER",
    );

    await testCanister.testHandleBlockAction(
      "approve_workflow",
      code,
      "U_OWNER",
      "",
    );

    const status = await testCanister.testGetApprovalStatus(code);
    expect(status).toEqual(["used"]);
  });

  // ─── deny_workflow happy path ──────────────────────────────────────────────

  it("should transition approval to #expired when deny_workflow is sent by the original requester", async () => {
    const code = await testCanister.testSeedApprovalRecord(
      "workspace_delete",
      "0_0",
      "U_OWNER",
    );

    await testCanister.testHandleBlockAction(
      "deny_workflow",
      code,
      "U_OWNER",
      "",
    );

    const status = await testCanister.testGetApprovalStatus(code);
    expect(status).toEqual(["expired"]);
  });
});
