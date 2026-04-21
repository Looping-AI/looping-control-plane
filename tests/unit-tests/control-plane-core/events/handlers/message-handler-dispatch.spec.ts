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
} from "../../../../setup";
import { withCassette } from "../../../../lib/cassette";

// ============================================
// dispatch_workflow path
//
// When the LLM responds with a `dispatch_workflow` tool call the message
// handler must:
//   1. Issue an execution token and build an ExecutionEnvelope
//   2. Call dispatchToEngine → #ok (engine mock)
//   3. Call SessionModel.markPending on the current turn
//   4. Return #ok([{ action: "dispatch_to_engine", result: { ok: null } }])
//      WITHOUT posting to Slack
//
// The test uses testMessageHandlerDispatch (real generateEnvelopeId and
// dispatchToEngine stubs) and verifies turn status via testGetTurnStatus.
//
// The cassette records only the OpenRouter call (no Slack HTTP traffic).
// The channel is a stable constant because it never appears in a
// chat.postMessage body that would need to match at playback time.
// ============================================

const BOT_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] ?? "not-needed-due-to-cassette";
const OPENROUTER_API_KEY =
  process.env["OPENROUTER_TEST_KEY"] ?? "not-needed-due-to-cassette";

// Stable channel ID — does not appear in cassette body, so it is safe to use a
// constant for both recording and playback.
const DISPATCH_TEST_CHANNEL = "C_DISPATCH_TEST";

describe("MessageHandler – dispatch_workflow path", () => {
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

  it("should mark the turn as pending and return dispatch_to_engine step", async () => {
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler-dispatch/dispatch-workflow";

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerDispatch(
          {
            user: "U_ADMIN",
            text: "List all workspaces for me.",
            channel: DISPATCH_TEST_CHANNEL,
            ts: "1700000020.000001",
            threadTs: [],
            isBotMessage: false,
            agentMetadata: [],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;

    // Handler must succeed
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      // The only step must be dispatch_to_engine (no post_to_slack)
      expect(response.ok.length).toBeGreaterThanOrEqual(1);
      const dispatchStep = response.ok.find(
        (s) => s.action === "dispatch_to_engine",
      );
      expect(dispatchStep).toBeDefined();
      if (dispatchStep) {
        expect("ok" in dispatchStep.result).toBe(true);
      }
      // No Slack post in the dispatch path
      const slackStep = response.ok.find((s) => s.action === "post_to_slack");
      expect(slackStep).toBeUndefined();
    }

    // After dispatch, the turn must be marked pending (turnId = "0_0")
    const statusResult = await (await testCanister.testGetTurnStatus("0_0"))();
    expect(statusResult).toEqual(["pending"]);
  });
});
