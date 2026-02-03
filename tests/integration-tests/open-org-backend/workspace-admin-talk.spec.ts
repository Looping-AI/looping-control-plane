import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createGroqAgent,
  idlFactory,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";
import { withCassette } from "../../lib/cassette";

describe("workspaceAdminTalk", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let canisterId: Principal;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a Groq agent with real API key for HTTP outcall tests
    ({ userIdentity } = await setupRegularUser(actor));
    await createGroqAgent(actor, adminIdentity);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should reject anonymous users from sending messages", async () => {
    actor.setPrincipal(Principal.anonymous());

    const result = await actor.workspaceAdminTalk(0n, "Hello Agent");
    expect(expectErr(result)).toEqual(
      "Please login before calling this function.",
    );
  });

  it("should reject regular members from sending messages", async () => {
    actor.setIdentity(userIdentity);

    const result = await actor.workspaceAdminTalk(0n, "Hello Agent");
    expect(expectErr(result)).toEqual(
      "Only workspace admins can perform this action.",
    );
  });

  it("should accept message from workspace admin", async () => {
    // Create a deferred actor for the HTTP outcall test
    const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
      idlFactory,
      canisterId,
    );
    deferredActor.setIdentity(adminIdentity);

    const { result } = await withCassette(
      pic,
      "integration-tests/open-org-backend/workspace-admin-talk/accept-message-authenticated-admin",
      () => deferredActor.workspaceAdminTalk(0n, "Hello Agent"),
      { ticks: 5 },
    );
    expectOk(await result);
  });

  it(
    "should execute tool calls and return final response",
    async () => {
      // Create a deferred actor for the HTTP outcall test
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(adminIdentity);

      // Ask the agent to use the echo tool - the LLM should call echo
      // Multi-turn: first call returns tool_use, second call returns final message
      const { result } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-echo",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Please use the echo tool to say 'Hello from tools!'",
          ),
        { ticks: 5, maxRounds: 10 }, // More rounds and ticks for multi-turn tool execution
      );
      const response = expectOk(await result);
      // The response should contain something about the echo result
      expect(response.length).toBeGreaterThan(0);
    },
    { timeout: 15000 },
  );

  it(
    "should create a value stream using save_value_stream tool",
    async () => {
      // Create a deferred actor for the HTTP outcall test
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(adminIdentity);

      // Step 1: Describe the problem - LLM will ask for confirmation
      const { result: confirmationResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-save-value-stream-request",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "I want to improve our customer onboarding process. The problem is that new users are getting confused during signup and dropping off. The goal is to achieve a smooth, intuitive onboarding flow with 90% completion rate.",
          ),
        { ticks: 5, maxRounds: 3 },
      );
      const confirmationResponse = expectOk(await confirmationResult);
      // LLM should ask about the name or ask to confirm
      expect(
        confirmationResponse.toLowerCase().includes("save") ||
          confirmationResponse.toLowerCase().includes("confirm") ||
          confirmationResponse.toLowerCase().includes("let me know"),
      ).toBe(true);

      // Value stream should not exist yet
      const valueStreamsResult = await actor.listValueStreams(0n);
      const valueStreams = expectOk(valueStreamsResult);
      expect(valueStreams.length).toBe(0);

      // Step 2: Confirm - LLM will use save_value_stream tool
      const { result: createResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-save-value-stream-confirm",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Yes, that looks good. Please create the Value Stream.",
          ),
        { ticks: 5, maxRounds: 6 }, // More rounds for tool execution
      );
      const createResponse = expectOk(await createResult);
      expect(createResponse.length).toBeGreaterThan(0);

      // Verify the value stream was actually created
      actor.setIdentity(adminIdentity);
      const newValueStreamsResult = await actor.listValueStreams(0n);
      const newValueStreams = expectOk(newValueStreamsResult);

      expect(newValueStreams.length).toBeGreaterThan(0);
      const createdStream = newValueStreams[0];
      expect(createdStream.name.toLowerCase()).toContain("onboarding");
      expect(createdStream.problem.toLowerCase()).toContain("confus");
      expect(createdStream.goal.toLowerCase()).toContain("completion");
    },
    { timeout: 20000 },
  );

  it(
    "should update an existing value stream and activate it",
    async () => {
      // First, create a value stream directly
      actor.setIdentity(adminIdentity);
      const createResult = await actor.createValueStream(0n, {
        name: "Initial Value Stream",
        problem: "Initial problem description",
        goal: "Initial goal",
      });
      const createdStream = expectOk(createResult);
      const streamId = createdStream.id;

      // Create a deferred actor for the HTTP outcall test
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(adminIdentity);

      // Ask the agent to update and activate the value stream
      const { result } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-update-value-stream",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            `Please update value stream ${streamId} with a refined problem: "Users are abandoning the signup process at the payment step" and goal: "Reduce payment step abandonment to under 5%". Also activate this value stream.`,
          ),
        { ticks: 5, maxRounds: 6 },
      );
      const response = expectOk(await result);
      expect(response.length).toBeGreaterThan(0);

      // Verify the value stream was updated and activated
      actor.setIdentity(adminIdentity);
      const getResult = await actor.getValueStream(0n, streamId);
      const updatedStream = expectOk(getResult);

      expect(updatedStream.problem.toLowerCase()).toContain("payment");
      expect(updatedStream.goal).toContain("5%");
      expect(updatedStream.status).toEqual({ active: null });
    },
    { timeout: 15000 },
  );

  it(
    "should handle multiple tool calls in a single conversation",
    async () => {
      // Create a deferred actor for the HTTP outcall test
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(adminIdentity);

      // Step 1: Simple echo request to establish conversation
      const { result: echoResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-multiple-echo",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Use the echo tool to say 'Starting workspace setup'",
          ),
        { ticks: 5, maxRounds: 6 },
      );
      const echoResponse = expectOk(await echoResult);
      expect(echoResponse.length).toBeGreaterThan(0);
      // Should acknowledge the tool use (may not include exact text)
      expect(
        echoResponse.toLowerCase().includes("workspace") ||
          echoResponse.toLowerCase().includes("setup"),
      ).toBe(true);

      // Step 2: Ask to create value stream - AI should propose and ask for confirmation
      const { result: createResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-multiple-create",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Create a value stream for improving our API response times. Problem: API endpoints are slow. Goal: Reduce average response time to under 200ms.",
          ),
        { ticks: 3, maxRounds: 5 },
      );
      const createResponse = expectOk(await createResult);
      expect(createResponse.length).toBeGreaterThan(0);
      // Should propose the value stream
      expect(createResponse.toLowerCase().includes("api")).toBe(true);

      // Step 3: Confirm creation - AI should call save_value_stream
      const { result: confirmResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-multiple-request",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Yes, that looks great! Please create it.",
          ),
        { ticks: 5, maxRounds: 6 },
      );
      const confirmResponse = expectOk(await confirmResult);
      expect(confirmResponse.length).toBeGreaterThan(0);

      // Verify the value stream was created
      actor.setIdentity(adminIdentity);
      const valueStreamsResult = await actor.listValueStreams(0n);
      const valueStreams = expectOk(valueStreamsResult);

      expect(valueStreams.length).toBeGreaterThan(0);
      const apiStream = valueStreams.find(
        (vs) =>
          vs.name.toLowerCase().includes("api") ||
          vs.problem.toLowerCase().includes("api"),
      );
      expect(apiStream).toBeDefined();
    },
    { timeout: 20000 },
  );

  it(
    "should create a plan for a value stream after user confirmation",
    async () => {
      // Set up workspace with a value stream (no plan)
      actor.setIdentity(adminIdentity);
      const vsResult = await actor.createValueStream(0n, {
        name: "Improve API Response Times",
        problem:
          "API endpoints are responding slowly, affecting user experience",
        goal: "Achieve average response time under 200ms for all critical endpoints",
      });
      const valueStream = expectOk(vsResult);
      const valueStreamId = valueStream.id;

      // Activate the value stream
      const activateResult = await actor.updateValueStream(
        0n,
        valueStreamId,
        [],
        [],
        [],
        [{ active: null }],
      );
      expectOk(activateResult);

      // Verify it has no plan initially
      const valueStreamsResult = await actor.listValueStreams(0n);
      const valueStreams = expectOk(valueStreamsResult);
      const targetStream = valueStreams.find((vs) => vs.id === valueStreamId);
      expect(targetStream).toBeDefined();
      expect(targetStream!.plan.length).toBe(0); // Optional type = empty array

      // Create deferred actor for multi-turn conversation
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(adminIdentity);

      // Turn 1: User asks what to do next - AI should suggest planning and ask clarifying questions
      const { result: askResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/planning-flow-ask-next-step",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            'What should we do next for the "Improve API Response Times" value stream?',
          ),
        { ticks: 3, maxRounds: 5 },
      );
      const askResponse = expectOk(await askResult);
      expect(askResponse.length).toBeGreaterThan(0);
      // Should mention planning or ask questions
      expect(
        askResponse.toLowerCase().includes("plan") ||
          askResponse.toLowerCase().includes("question"),
      ).toBe(true);

      // Turn 2: User provides context - AI should research and propose plan
      const { result: planResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/planning-flow-research-and-propose",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            `Great! Here's the context:
          
          - Small team: 2 developers
          - Timeline: 3 weeks
          - Available resources: Can use caching solutions
          - Preferences: Quick wins over complex refactoring`,
          ),
        { ticks: 8, maxRounds: 15 }, // More rounds for research + planning
      );
      const planResponse = expectOk(await planResult);
      expect(planResponse.length).toBeGreaterThan(0);
      // Should mention plan details or research findings
      expect(
        planResponse.toLowerCase().includes("plan") ||
          planResponse.toLowerCase().includes("approach") ||
          planResponse.toLowerCase().includes("steps") ||
          planResponse.toLowerCase().includes("research"),
      ).toBe(true);

      // Turn 3: User confirms - AI saves the plan
      const { result: confirmResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/planning-flow-confirm-and-save",
        () => deferredActor.workspaceAdminTalk(0n, "This plan looks great!"),
        { ticks: 5, maxRounds: 8 },
      );
      const confirmResponse = expectOk(await confirmResult);
      expect(confirmResponse.length).toBeGreaterThan(0);

      // Verify the plan was saved
      actor.setIdentity(adminIdentity);
      const updatedStreamsResult = await actor.listValueStreams(0n);
      const updatedStreams = expectOk(updatedStreamsResult);
      const streamWithPlan = updatedStreams.find(
        (vs) => vs.id === valueStreamId,
      );

      expect(streamWithPlan).toBeDefined();
      expect(streamWithPlan!.plan.length).toBe(1); // Has plan now

      if (streamWithPlan!.plan.length > 0) {
        const plan = streamWithPlan!.plan[0]!;
        expect(plan.summary.length).toBeGreaterThan(0);
        expect(plan.currentState.length).toBeGreaterThan(0);
        expect(plan.targetState.length).toBeGreaterThan(0);
        expect(plan.steps.length).toBeGreaterThan(0);
        expect(plan.risks.length).toBeGreaterThan(0);
        expect(plan.resources.length).toBeGreaterThan(0);
      }
    },
    { timeout: 45000 },
  ); // Longer timeout for 3-turn conversation with web research
});
