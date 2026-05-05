import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  freshDeferredTestCanister,
  type TestCanisterService,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";
import { resolveSpecsChannel } from "../../../helpers";

// ============================================
// ExecutionAsyncEffectService – end-to-end
//
// Tests that after testRunAsyncEffect is called:
//   - #milestone: SlackWrapper.postMessage is called with the milestone
//     summary and the turn remains #pending
//   - #complete: SlackWrapper.postMessage is called with the completion
//     summary and the turn is advanced to #succeeded
//
// testRunAsyncEffect seeds the botToken into the test secrets store and
// delegates to ExecutionAsyncEffectService.processEffect, which mirrors the
// production path in main.mo without live Schnorr key derivation.
//
// Cassettes record the Slack chat.postMessage HTTP outcall.
// To re-record: RECORD_CASSETTES=true bun test execution-async-effect-service.spec.ts
// ============================================

const BOT_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] ?? "not-needed-due-to-cassette";

const EFFECT_TS = "1700000030.000001";

// Agent 0 = workspace-admin, pre-seeded by AgentModel.defaultState()
const AGENT_ID = 0n;
const WORKSPACE_ID = 0n;

describe("ExecutionAsyncEffectService – end-to-end", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeAll(async () => {
    pic = (await createDeferredTestCanister()).pic;
  });

  beforeEach(async () => {
    testCanister = (await freshDeferredTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("milestone: should post to Slack and leave turn #awaitingWorkflow", async () => {
    const cassetteName =
      "control-plane-core/unit-tests/services/execution-async-effect-service/milestone-post";
    const channel = await resolveSpecsChannel(cassetteName);

    // Seed an #awaitingWorkflow turn (no HTTP outcalls — tick and await manually)
    const turnIdThunk = await testCanister.testSeedPendingTurn(
      AGENT_ID,
      channel,
      EFFECT_TS,
      [],
    );
    await pic.tick(2);
    const turnId = await turnIdThunk();

    // Issue a token for this turn
    const tokenThunk = await testCanister.testIssueEffectToken(
      turnId,
      WORKSPACE_ID,
    );
    await pic.tick(2);
    const nonce = await tokenThunk();

    // Run the milestone effect — Slack postMessage is the HTTP outcall
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testRunAsyncEffect(
          { post: null },
          "/execution/milestone",
          JSON.stringify({
            envelopeNonce: nonce,
            humanSummary: "Step 1 done.",
          }),
          BOT_TOKEN,
        ),
      { ticks: 5, maxRounds: 3 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);

    // Milestone does NOT complete the turn — it must stay #awaitingWorkflow
    const status = await (await testCanister.testGetEffectTurnStatus(turnId))();
    expect(status).toEqual(["awaitingWorkflow"]);
  });

  it("complete: should post to Slack and mark turn #succeeded", async () => {
    const cassetteName =
      "control-plane-core/unit-tests/services/execution-async-effect-service/complete-success";
    const channel = await resolveSpecsChannel(cassetteName);

    // Seed a #running turn so processEffect takes the normal completion path
    // (not the resume branch, which requires a live resumeAdminTurn callback).
    const turnIdThunk = await testCanister.testSeedRunningTurn(
      AGENT_ID,
      channel,
      EFFECT_TS,
      [],
    );
    await pic.tick(2);
    const turnId = await turnIdThunk();

    // Issue a token for this turn
    const tokenThunk = await testCanister.testIssueEffectToken(
      turnId,
      WORKSPACE_ID,
    );
    await pic.tick(2);
    const nonce = await tokenThunk();

    // Run the complete effect — Slack postMessage is the HTTP outcall
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testRunAsyncEffect(
          { post: null },
          "/execution/complete",
          JSON.stringify({
            envelopeNonce: nonce,
            humanSummary: "Workflow complete.",
            status: "completed",
            stats: { inputTokens: 100, outputTokens: 50 },
          }),
          BOT_TOKEN,
        ),
      { ticks: 5, maxRounds: 3 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);

    // Complete MUST advance the turn to #succeeded
    const status = await (await testCanister.testGetEffectTurnStatus(turnId))();
    expect(status).toEqual(["succeeded"]);
  });

  it("complete (awaitingWorkflow): should invoke resumeAdminTurn and mark turn #succeeded", async () => {
    // Seed a #awaitingWorkflow turn — this is the production path where
    // the engine finishes and Core must resume the admin agent loop.
    const cassetteName =
      "control-plane-core/unit-tests/services/execution-async-effect-service/complete-awaiting-workflow-resume";
    const channel = await resolveSpecsChannel(cassetteName);

    const turnIdThunk = await testCanister.testSeedPendingTurn(
      AGENT_ID,
      channel,
      EFFECT_TS,
      [],
    );
    await pic.tick(2);
    const turnId = await turnIdThunk();

    // Issue a token for this turn
    const tokenThunk = await testCanister.testIssueEffectToken(
      turnId,
      WORKSPACE_ID,
    );
    await pic.tick(2);
    const nonce = await tokenThunk();

    // Run the complete effect via the resume-enabled variant.
    // resumeAdminTurn stub returns #ok immediately; TurnCompletionService
    // then posts to Slack (captured by cassette) and marks the turn #succeeded.
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testRunAsyncEffectWithResume(
          { post: null },
          "/execution/complete",
          JSON.stringify({
            envelopeNonce: nonce,
            humanSummary: "Workflow complete.",
            status: "completed",
            stats: { inputTokens: 100, outputTokens: 50 },
          }),
          BOT_TOKEN,
        ),
      { ticks: 5, maxRounds: 3 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);

    // resumeAdminTurn stub returns #ok → TurnCompletionService posts to Slack
    // and advances the turn to #succeeded.
    const status = await (await testCanister.testGetEffectTurnStatus(turnId))();
    expect(status).toEqual(["succeeded"]);
  });
});
