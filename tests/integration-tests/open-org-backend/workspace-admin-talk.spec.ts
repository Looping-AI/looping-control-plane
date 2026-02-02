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
      expect(echoResponse.toLowerCase()).toContain("starting workspace setup");

      // Step 2: Create value stream in the same conversation (conversation history maintained)
      const { result: createResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-multiple-create",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Create a value stream for improving our API response times. Problem: API endpoints are slow. Goal: Reduce average response time to under 200ms.",
          ),
        { ticks: 5, maxRounds: 10 }, // More rounds for tool execution
      );
      const createResponse = expectOk(await createResult);
      expect(createResponse.length).toBeGreaterThan(0);

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
});
