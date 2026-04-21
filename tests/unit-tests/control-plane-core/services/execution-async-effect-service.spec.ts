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

// Stable constants — do not appear in the Slack API response body,
// so they are safe to use as-is across record and playback sessions.
const EFFECT_CHANNEL = "C_EFFECT_TEST";
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

  it("milestone: should post to Slack and leave turn #pending", async () => {
    // Seed a pending turn (no HTTP outcalls — tick and await manually)
    const turnIdThunk = await testCanister.testSeedPendingTurn(
      AGENT_ID,
      EFFECT_CHANNEL,
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
      "unit-tests/control-plane-core/services/execution-async-effect-service/milestone-post",
      () =>
        testCanister.testRunAsyncEffect(
          { post: null },
          "/execution/milestone",
          JSON.stringify({ tokenNonce: nonce, humanSummary: "Step 1 done." }),
          BOT_TOKEN,
        ),
      { ticks: 5, maxRounds: 3 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);

    // Milestone does NOT complete the turn — it must still be #pending
    const status = await (await testCanister.testGetEffectTurnStatus(turnId))();
    expect(status).toEqual(["pending"]);
  });

  it("complete: should post to Slack and mark turn #succeeded", async () => {
    // Seed a pending turn
    const turnIdThunk = await testCanister.testSeedPendingTurn(
      AGENT_ID,
      EFFECT_CHANNEL,
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
      "unit-tests/control-plane-core/services/execution-async-effect-service/complete-success",
      () =>
        testCanister.testRunAsyncEffect(
          { post: null },
          "/execution/complete",
          JSON.stringify({
            tokenNonce: nonce,
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
});
