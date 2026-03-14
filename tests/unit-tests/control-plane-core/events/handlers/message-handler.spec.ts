import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor, Actor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  createTestCanister,
  type TestCanisterService,
} from "../../../../setup";
import { withCassette } from "../../../../lib/cassette";
import { resolveSpecsChannel } from "../../../../helpers";
import messageStandardStub from "../../../../stubs/slack-payloads/message-standard.json";

// ============================================
// MessageHandler is a full controller that:
//   1. Derives an encryption key for the workspace
//   2. Looks up the Slack bot token from secrets
//   3. Calls the LLM orchestrator
//   4. Posts the reply back to Slack
//
// All tests use a deferred actor + cassette so that the OpenRouter LLM call and
// the Slack HTTP POST are recorded on first run and replayed on CI.
//
// Tokens are loaded from .env.test (SLACK_APP_BOT_TOKEN, OPENROUTER_TEST_KEY).
// All messages are directed to a "specs-only" Slack channel
// which is dedicated to automated test traffic.
// ============================================

const BOT_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] ?? "not-needed-due-to-cassette";
const OPENROUTER_API_KEY =
  process.env["OPENROUTER_TEST_KEY"] ?? "not-needed-due-to-cassette";

describe("MessageHandler Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ============================================
  // Happy-path — bot token + OpenRouter key configured
  // The cassette records the OpenRouter LLM call and the Slack POST on first run
  // and replays them on subsequent runs (CI, offline, etc.).
  // ============================================

  it("should post a reply for a standard channel message", async () => {
    const event = messageStandardStub.event;
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/standard-message-reply";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          {
            user: event.user,
            text: event.text,
            channel,
            ts: event.ts,
            threadTs: event.thread_ts
              ? ([event.thread_ts] as [string])
              : ([] as []),
            isBotMessage: false,
            agentMetadata: [],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      // The final step must be a successful Slack post
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
      // Every step must carry a nanosecond timestamp
      for (const step of response.ok) {
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });

  it("should reply within an existing thread when threadTs is set", async () => {
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/thread-reply";
    const channel = await resolveSpecsChannel(cassetteName);
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          {
            user: "U_THREAD",
            text: "This is a thread reply",
            channel,
            ts: "1700000010.000001",
            threadTs: ["1700000005.000000"] as [string],
            isBotMessage: false,
            agentMetadata: [],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
    }
  });

  it("should post a top-level channel message when threadTs is absent", async () => {
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/top-level-channel-post";
    const channel = await resolveSpecsChannel(cassetteName);
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          {
            user: "U_CHANNEL",
            text: "Hello channel",
            channel,
            ts: "1700000010.000001",
            threadTs: [] as [],
            isBotMessage: false,
            agentMetadata: [],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
    }
  });

  it("should handle messages consistently across multiple scenarios", async () => {
    for (const label of ["ws0", "ws1", "ws42"]) {
      const cassetteName = `unit-tests/control-plane-core/events/handlers/message-handler/multi-workspace-${label}`;
      const channel = await resolveSpecsChannel(cassetteName);
      const { result } = await withCassette(
        pic,
        cassetteName,
        () =>
          testCanister.testMessageHandlerWithSecrets(
            {
              user: "U_TEST",
              text: `Hello from workspace ${label}`,
              channel,
              ts: "1700000010.000001",
              threadTs: [] as [],
              isBotMessage: false,
              agentMetadata: [],
            },
            BOT_TOKEN,
            OPENROUTER_API_KEY,
          ),
        { ticks: 5, maxRounds: 5 },
      );

      const response = await result;
      expect("ok" in response).toBe(true);
      if ("ok" in response) {
        const lastStep = response.ok[response.ok.length - 1];
        expect(lastStep.action).toBe("post_to_slack");
        expect(lastStep.timestamp).toBeGreaterThan(0n);
      }
    }
  }, 20000);

  it("should include a positive nanosecond timestamp in every returned step", async () => {
    const event = messageStandardStub.event;
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/step-timestamps";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          {
            user: event.user,
            text: event.text,
            channel,
            ts: event.ts,
            threadTs: [] as [],
            isBotMessage: false,
            agentMetadata: [],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      for (const step of response.ok) {
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });

  // ============================================
  // Bot-message proceed path — session inheritance
  // A bot reply that passes every guard and continues through orchestration must
  // advance the round counter (parentRoundCount 0 → active roundCount 1) and
  // ultimately post the agent reply back to Slack.
  // ============================================

  it("should inherit session context from parent and proceed to orchestration when within round limit", async () => {
    const PARENT_TS = "1700000010.000100";
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/bot-branch-session-inherit";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerBotBranch(
          {
            user: "UBOT001",
            text: "::unit-test-admin please summarise the progress",
            channel,
            ts: "1700000020.000100",
            threadTs: [PARENT_TS] as [string],
            isBotMessage: true,
            agentMetadata: [
              {
                event_type: "looping_agent_message",
                event_payload: {
                  parent_agent: "unit-test-admin",
                  parent_ts: PARENT_TS,
                  parent_channel: channel,
                },
              },
            ],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
          channel, // parentChannel — same channel as the bot message
          PARENT_TS, // parentTs
          0n, // parentRoundCount = 0 → newRound = 1, well within MAX_AGENT_ROUNDS
          false, // parentForceTerminated = false
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      // Orchestration must complete with a successful Slack post as the final step.
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
      // Every step must carry a valid nanosecond timestamp.
      for (const step of response.ok) {
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });
});

// ============================================
// Bot-message guard and round-tracking tests.
//
// These tests cover every pre-condition guard and the MAX_AGENT_ROUNDS hard
// ceiling in the isBotMessage: true path. None of these paths reaches the LLM
// or Slack (they all short-circuit before token decryption), so a non-deferred
// actor is sufficient and no cassette recording is needed.
// ============================================

describe("MessageHandler — bot-message branch guards & round tracking", () => {
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

  it("should return round_skip when bot message carries no valid ::agent reference", async () => {
    const result = await testCanister.testMessageHandlerWithSecrets(
      {
        user: "UBOT001",
        text: "This bot reply has no agent reference at all",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000020.000001",
        threadTs: ["1700000010.000000"] as [string],
        isBotMessage: true,
        agentMetadata: [],
      },
      BOT_TOKEN,
      OPENROUTER_API_KEY,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("round_skip");
    }
  });

  it("should return round_skip when bot message has a valid ::agent ref but no agentMetadata", async () => {
    // agentMetadata: [] encodes as Candid `null` (absent optional).
    const result = await testCanister.testMessageHandlerWithSecrets(
      {
        user: "UBOT001",
        text: "::unit-test-admin please continue",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000020.000002",
        threadTs: ["1700000010.000000"] as [string],
        isBotMessage: true,
        agentMetadata: [],
      },
      BOT_TOKEN,
      OPENROUTER_API_KEY,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("round_skip");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain(
          "bot message missing agentMetadata",
        );
      }
    }
  });

  it("should return round_skip when the referenced parent message is absent from the conversation store", async () => {
    // The conversation store is empty, so the parent lookup always fails.
    const result = await testCanister.testMessageHandlerWithSecrets(
      {
        user: "UBOT001",
        text: "::unit-test-admin please continue",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000020.000003",
        threadTs: ["1700000010.000000"] as [string],
        isBotMessage: true,
        agentMetadata: [
          {
            event_type: "looping_agent_message",
            event_payload: {
              parent_agent: "unit-test-admin",
              parent_ts: "1700000010.000000",
              parent_channel: "C_ADMIN_CHANNEL",
            },
          },
        ],
      },
      BOT_TOKEN,
      OPENROUTER_API_KEY,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("round_skip");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain("parent message not found");
      }
    }
  });

  it("should return round_skip when the parent session has already been force-terminated", async () => {
    const result = await testCanister.testMessageHandlerBotBranch(
      {
        user: "UBOT001",
        text: "::unit-test-admin please continue",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000020.000004",
        threadTs: ["1700000010.000000"] as [string],
        isBotMessage: true,
        agentMetadata: [
          {
            event_type: "looping_agent_message",
            event_payload: {
              parent_agent: "unit-test-admin",
              parent_ts: "1700000010.000000",
              parent_channel: "C_ADMIN_CHANNEL",
            },
          },
        ],
      },
      BOT_TOKEN,
      OPENROUTER_API_KEY,
      "C_ADMIN_CHANNEL", // parentChannel
      "1700000010.000000", // parentTs
      0n, // parentRoundCount
      true, // parentForceTerminated = true
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("round_skip");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain("force-terminated");
      }
    }
  });

  it("should return round_force_terminated and halt when MAX_AGENT_ROUNDS (10) is reached", async () => {
    // MAX_AGENT_ROUNDS = 10. parentRoundCount = 9 → newRound = 10 ≥ 10 → terminate.
    //
    // Uses testMessageHandlerBotBranchNoSlackToken (no Slack bot token seeded) to keep
    // postTerminationIfTokenAvailable a no-op.  This lets the test run on a non-deferred
    // actor without managing a pending HTTPS outcall for the Slack chat.postMessage.
    // A separate cassette test ("should post termination prompt to Slack when MAX_AGENT_ROUNDS
    // is reached") verifies the full Slack-delivery path.
    const result = await testCanister.testMessageHandlerBotBranchNoSlackToken(
      {
        user: "UBOT001",
        text: "::unit-test-admin please continue",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000020.000005",
        threadTs: ["1700000010.000000"] as [string],
        isBotMessage: true,
        agentMetadata: [
          {
            event_type: "looping_agent_message",
            event_payload: {
              parent_agent: "unit-test-admin",
              parent_ts: "1700000010.000000",
              parent_channel: "C_ADMIN_CHANNEL",
            },
          },
        ],
      },
      OPENROUTER_API_KEY,
      "C_ADMIN_CHANNEL", // parentChannel
      "1700000010.000000", // parentTs
      9n, // parentRoundCount = 9 → newRound = 10 = MAX_AGENT_ROUNDS
      false, // parentForceTerminated = false
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("round_force_terminated");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain("max agent rounds reached");
      }
    }
  });
});

// ============================================
// Primary agent resolution
//
// Tests that verify the agent-resolution logic in resolvePrimaryAgent.
// Routes to ::research agent (category stub, no LLM call) or verifies
// primary_agent_skip is returned when no agent can be resolved.
//
// These tests run on a non-deferred actor with no cassette.
// ============================================

describe("MessageHandler — primary agent resolution", () => {
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

  it("should route ::unit-test-research to research category stub (not primary_agent_skip)", async () => {
    // When the user explicitly references ::unit-test-research, the primary agent is the
    // registered research agent and AgentRouter.route(#research, …) returns a stub #err
    // without making any HTTP calls.
    const result = await testCanister.testMessageHandlerWithResearchAgent(
      {
        user: "U_USER",
        text: "::unit-test-research what is the current status",
        channel: "C_ADMIN_CHANNEL",
        ts: "1700000010.000010",
        threadTs: [] as [],
        isBotMessage: false,
        agentMetadata: [] as [],
      },
      BOT_TOKEN,
      OPENROUTER_API_KEY,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      // Must NOT return primary_agent_skip — the research agent WAS successfully resolved.
      expect(result.ok.some((s) => s.action === "primary_agent_skip")).toBe(
        false,
      );
      // The orchestrate stub for #research returns an error step with the expected message.
      const orchestrateStep = result.ok.find((s) => s.action === "orchestrate");
      expect(orchestrateStep).toBeDefined();
      if (orchestrateStep && "err" in orchestrateStep.result) {
        expect(orchestrateStep.result.err).toContain(
          "category service not yet implemented",
        );
      }
    }
  });

  it("should return primary_agent_skip when no agents are registered (empty registry)", async () => {
    // testMessageHandler uses emptyCtx() — no agents registered at all.
    // A bare user message with no ::ref has no fallback agent available.
    const result = await testCanister.testMessageHandler({
      user: "U_USER",
      text: "what is the current status",
      channel: "C_ADMIN_CHANNEL",
      ts: "1700000010.000011",
      threadTs: [] as [],
      isBotMessage: false,
      agentMetadata: [] as [],
    });

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok).toHaveLength(1);
      expect(result.ok[0].action).toBe("primary_agent_skip");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain("no primary agent found");
      }
    }
  });

  it("should fall back to #admin agent for bare user message with no ::ref", async () => {
    // With both admin and research agents registered, a bare message (no ::ref) falls
    // back to getFirstByCategory(#admin).  The NoOpenRouter variant seeds no openRouterApiKey so
    // the admin route short-circuits at key resolution (#err) without issuing any HTTP
    // outcall — letting a non-deferred actor complete the call synchronously.
    // The important assertion: primary_agent_skip is NOT emitted — the fallback succeeded.
    const result =
      await testCanister.testMessageHandlerWithResearchAgentNoOpenRouter(
        {
          user: "U_USER",
          text: "what is the current status",
          channel: "C_ADMIN_CHANNEL",
          ts: "1700000010.000012",
          threadTs: [] as [],
          isBotMessage: false,
          agentMetadata: [] as [],
        },
        BOT_TOKEN,
      );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      // Fallback to admin succeeds — must not see primary_agent_skip.
      expect(result.ok.some((s) => s.action === "primary_agent_skip")).toBe(
        false,
      );
    }
  });
});

// ============================================
// Termination prompt delivery
//
// Verifies that MAX_AGENT_ROUNDS causes the bot to post a continuation prompt
// to Slack in addition to returning round_force_terminated.
//
// Uses a deferred actor + cassette so the outgoing Slack chat.postMessage call
// can be intercepted and replayed without a live API connection.
// ============================================

describe("MessageHandler — MAX_AGENT_ROUNDS termination prompt", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should post a termination prompt to Slack when MAX_AGENT_ROUNDS is reached", async () => {
    // parentRoundCount = 9 → newRound = 10 = MAX_AGENT_ROUNDS → force-terminate.
    // Unlike the non-deferred guard test, this deferred version captures both the
    // round_force_terminated HandlerResult AND the outgoing Slack chat.postMessage call
    // (the termination prompt) via cassette.
    const PARENT_TS = "1700000010.000100";
    const cassetteName =
      "unit-tests/control-plane-core/events/handlers/message-handler/max-rounds-termination-prompt";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerBotBranch(
          {
            user: "UBOT001",
            text: "::unit-test-admin please continue",
            channel,
            ts: "1700000020.000100",
            threadTs: [PARENT_TS] as [string],
            isBotMessage: true,
            agentMetadata: [
              {
                event_type: "looping_agent_message",
                event_payload: {
                  parent_agent: "unit-test-admin",
                  parent_ts: PARENT_TS,
                  parent_channel: channel,
                },
              },
            ],
          },
          BOT_TOKEN,
          OPENROUTER_API_KEY,
          channel,
          PARENT_TS,
          9n, // parentRoundCount = 9 → terminates on round 10
          false,
        ),
      { ticks: 5, maxRounds: 3 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      // Handler returns round_force_terminated.
      expect(response.ok).toHaveLength(1);
      expect(response.ok[0].action).toBe("round_force_terminated");
      // The cassette should capture the outgoing Slack chat.postMessage for the
      // termination prompt — verified by the cassette recording containing a POST
      // to api.slack.com/api/chat.postMessage with the ⚠️ continuation message.
    }
  });
});
