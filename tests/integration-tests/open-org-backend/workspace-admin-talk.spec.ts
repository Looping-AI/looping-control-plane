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
      // Extract the final agent response
      const agentMessage = confirmationResponse.find(
        (msg) => "agent" in msg.author,
      );
      expect(agentMessage).toBeDefined();
      const responseText = agentMessage!.content;
      // LLM should ask about the name or ask to confirm
      expect(
        responseText.toLowerCase().includes("save") ||
          responseText.toLowerCase().includes("confirm") ||
          responseText.toLowerCase().includes("let me know"),
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
      // Extract the final agent response
      const echoAgentMessage = echoResponse.find(
        (msg) => "agent" in msg.author,
      );
      expect(echoAgentMessage).toBeDefined();
      const echoText = echoAgentMessage!.content;
      // Should acknowledge the tool use (may not include exact text)
      expect(
        echoText.toLowerCase().includes("workspace") ||
          echoText.toLowerCase().includes("setup"),
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
      // Extract the final agent response
      const createAgentMessage = createResponse.find(
        (msg) => "agent" in msg.author,
      );
      expect(createAgentMessage).toBeDefined();
      const createText = createAgentMessage!.content;
      // Should propose the value stream
      expect(createText.toLowerCase().includes("api")).toBe(true);

      // Step 3: Confirm creation - AI should call save_value_stream
      const { result: confirmResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/tool-call-multiple-request",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Yes, that looks great! Please create it.",
          ),
        { ticks: 5, maxRounds: 12 },
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
      // Extract the final agent response
      const askAgentMessage = askResponse.find((msg) => "agent" in msg.author);
      expect(askAgentMessage).toBeDefined();
      const askText = askAgentMessage!.content;
      // Should mention planning or ask questions
      expect(
        askText.toLowerCase().includes("plan") ||
          askText.toLowerCase().includes("question"),
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
      // Extract the final agent response
      const planAgentMessage = planResponse.find(
        (msg) => "agent" in msg.author,
      );
      expect(planAgentMessage).toBeDefined();
      const planText = planAgentMessage!.content;
      // Should mention plan details or research findings
      expect(
        planText.toLowerCase().includes("plan") ||
          planText.toLowerCase().includes("approach") ||
          planText.toLowerCase().includes("steps") ||
          planText.toLowerCase().includes("research"),
      ).toBe(true);

      // Turn 3: User confirms - AI saves the plan
      const { result: confirmResult } = await withCassette(
        pic,
        "integration-tests/open-org-backend/workspace-admin-talk/planning-flow-confirm-and-save",
        () =>
          deferredActor.workspaceAdminTalk(
            0n,
            "Yes, save the plan. Let's proceed!",
          ),
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

  describe("Metric Management Tools", () => {
    it(
      "should create a new metric through conversation",
      async () => {
        // Create deferred actor for multi-turn conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask the agent to create a metric
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-create-metric",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              "Please create a metric called 'Weekly Active Users' that measures the count of unique users who log in each week. Use 'count' as the unit and keep data for 365 days.",
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Verify the metric was created
        actor.setIdentity(adminIdentity);
        const metricsResult = await actor.listMetrics();
        const metrics = expectOk(metricsResult);

        const createdMetric = metrics.find((m) =>
          m.name.toLowerCase().includes("weekly active"),
        );
        expect(createdMetric).toBeDefined();
        expect(createdMetric!.unit).toBe("count");
        expect(createdMetric!.retentionDays).toBe(365n);
        expect(createdMetric!.description.length).toBeGreaterThan(0);
      },
      { timeout: 15000 },
    );

    it(
      "should update an existing metric's configuration",
      async () => {
        // First, register a metric directly
        actor.setIdentity(adminIdentity);
        const createResult = await actor.registerMetric({
          name: "Response Time",
          description: "API response time",
          unit: "ms",
          retentionDays: 90n,
        });
        const metric = expectOk(createResult);
        const metricId = metric.id;

        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask the agent to update the metric
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-update-metric",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Please update metric ${metricId} to have a better description: "Average API response time for critical endpoints" and increase retention to 365 days.`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Verify the metric was updated
        actor.setIdentity(adminIdentity);
        const getResult = await actor.getMetric(metricId);
        const updatedMetric = expectOk(getResult);

        expect(updatedMetric.description).toContain("critical endpoints");
        expect(updatedMetric.retentionDays).toBe(365n);
        expect(updatedMetric.unit).toBe("ms"); // Should remain unchanged
        expect(updatedMetric.name).toBe("Response Time"); // Should remain unchanged
      },
      { timeout: 15000 },
    );

    it(
      "should retrieve metric datapoints through conversation",
      async () => {
        // Set up: Create metric and record some datapoints
        actor.setIdentity(adminIdentity);
        const metricResult = await actor.registerMetric({
          name: "User Signups",
          description: "Daily user signups",
          unit: "count",
          retentionDays: 90n,
        });
        const metric = expectOk(metricResult);
        const metricId = metric.id;

        // Record some datapoints
        const recordResult1 = await actor.recordMetricDatapoint(
          metricId,
          100.0,
          { manual: "test-source-1" },
        );
        expectOk(recordResult1);

        const recordResult2 = await actor.recordMetricDatapoint(
          metricId,
          150.0,
          { manual: "test-source-2" },
        );
        expectOk(recordResult2);

        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask the agent to retrieve datapoints
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-get-datapoints",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `What are the latest datapoints for metric ${metricId}? Show me the last 10.`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Extract the final agent response
        const agentMessage = response.find((msg) => "agent" in msg.author);
        expect(agentMessage).toBeDefined();
        const responseText = agentMessage!.content;

        // Should mention the datapoints or their values
        expect(
          responseText.includes("100") || responseText.includes("150"),
        ).toBe(true);
      },
      { timeout: 15000 },
    );

    it(
      "should handle metric name conflicts gracefully",
      async () => {
        // Create a metric with a specific name
        actor.setIdentity(adminIdentity);
        const createResult = await actor.registerMetric({
          name: "Conversion Rate",
          description: "User conversion rate",
          unit: "percent",
          retentionDays: 90n,
        });
        expectOk(createResult);

        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Try to create another metric with the same name
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-duplicate-name",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              'Create a metric called "Conversion Rate" that tracks daily conversions.',
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Extract the final agent response
        const agentMessage = response.find((msg) => "agent" in msg.author);
        expect(agentMessage).toBeDefined();
        const responseText = agentMessage!.content;

        // Should mention the error or conflict
        expect(
          responseText.toLowerCase().includes("already exists") ||
            responseText.toLowerCase().includes("duplicate") ||
            responseText.toLowerCase().includes("conflict"),
        ).toBe(true);
      },
      { timeout: 15000 },
    );

    it(
      "should validate retention days bounds",
      async () => {
        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Try to create a metric with invalid retention (too low)
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-invalid-retention",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              "Create a metric called 'Test Metric' with unit 'count' and retention of 10 days.",
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Extract the final agent response
        const agentMessage = response.find((msg) => "agent" in msg.author);
        expect(agentMessage).toBeDefined();
        const responseText = agentMessage!.content;

        // Should mention the validation error
        expect(
          responseText.toLowerCase().includes("30") ||
            responseText.toLowerCase().includes("minimum") ||
            responseText.toLowerCase().includes("retention"),
        ).toBe(true);
      },
      { timeout: 15000 },
    );

    it(
      "should handle non-existent metric updates gracefully",
      async () => {
        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Try to update a non-existent metric
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-update-nonexistent",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              "Update metric 99999 to have a new description.",
            ),
          { ticks: 5, maxRounds: 6 },
        );
        const response = expectOk(await result);
        expect(response.length).toBeGreaterThan(0);

        // Extract the final agent response
        const agentMessage = response.find((msg) => "agent" in msg.author);
        expect(agentMessage).toBeDefined();
        const responseText = agentMessage!.content;

        // LLM should ask for clarification or provide a response
        // (it may ask for more details since the metric doesn't exist)
        expect(responseText.length).toBeGreaterThan(0);
        // The LLM typically asks "Could you please provide..." for missing metrics
        expect(
          responseText.toLowerCase().includes("provide") ||
            responseText.toLowerCase().includes("description") ||
            responseText.toLowerCase().includes("update"),
        ).toBe(true);
      },
      { timeout: 15000 },
    );

    it(
      "should preserve createdBy and createdAt when updating metrics",
      async () => {
        // Create a metric
        actor.setIdentity(adminIdentity);
        const createResult = await actor.registerMetric({
          name: "Test Metric",
          description: "Original description",
          unit: "count",
          retentionDays: 90n,
        });
        const metric = expectOk(createResult);
        const metricId = metric.id;

        // Get original metric
        const originalMetric = expectOk(await actor.getMetric(metricId));
        const originalCreatedBy = originalMetric.createdBy.toString();
        const originalCreatedAt = originalMetric.createdAt;

        // Create deferred actor for the conversation
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Update the metric
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/metrics-update-preserve-metadata",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Update metric ${metricId} with description "Updated description".`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        expectOk(await result);

        // Verify metadata was preserved
        actor.setIdentity(adminIdentity);
        const updatedMetric = expectOk(await actor.getMetric(metricId));

        expect(updatedMetric.createdBy.toString()).toBe(originalCreatedBy);
        expect(updatedMetric.createdAt).toBe(originalCreatedAt);
        expect(updatedMetric.description).toBe("Updated description");
      },
      { timeout: 15000 },
    );
  });

  describe("Objective Management", () => {
    it(
      "should create an objective through LLM conversation",
      async () => {
        // First setup: create a value stream and metric
        actor.setIdentity(adminIdentity);
        const vsResult = await actor.createValueStream(0n, {
          name: "User Onboarding",
          problem: "Low signup completion",
          goal: "Achieve 90% completion rate",
        });
        const valueStream = expectOk(vsResult);
        const vsId = valueStream.id;

        // Activate the value stream
        const activateResult = await actor.updateValueStream(
          0n,
          vsId,
          [],
          [],
          [],
          [{ active: null }],
        );
        expectOk(activateResult);

        const metricResult = await actor.registerMetric({
          name: "Signup Completion Rate",
          description: "Percentage of users who complete signup",
          unit: "%",
          retentionDays: 90n,
        });
        const metric = expectOk(metricResult);
        const metricId = metric.id;

        // Create a deferred actor for the HTTP outcall test
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask LLM to create an objective
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/tool-call-create-objective",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Create a target objective called "90% Signup Completion" for the User Onboarding value stream. Use metric ${metricId} (computation: "metric_${metricId}"). Target: 90% completion rate.`,
            ),
          { ticks: 5, maxRounds: 15 },
        );
        expectOk(await result);

        // Verify the objective was created
        actor.setIdentity(adminIdentity);
        const objectives = expectOk(await actor.listObjectives(0n, vsId));
        expect(objectives.length).toBeGreaterThan(0);
        const createdObj = objectives[0];
        expect(createdObj.name).toContain("90%");
        expect(createdObj.metricIds.length).toBe(1);
        expect(createdObj.metricIds[0]).toBe(metricId);
      },
      { timeout: 30000 },
    );

    it(
      "should update an objective with new target",
      async () => {
        // Setup: create value stream, metric, and objective
        actor.setIdentity(adminIdentity);
        const vsResult = await actor.createValueStream(0n, {
          name: "Product Quality",
          problem: "Bug reports increasing",
          goal: "Reduce critical bugs to zero",
        });
        const valueStream = expectOk(vsResult);
        const vsId = valueStream.id;

        // Activate the value stream
        const activateResult = await actor.updateValueStream(
          0n,
          vsId,
          [],
          [],
          [],
          [{ active: null }],
        );
        expectOk(activateResult);

        const metricResult = await actor.registerMetric({
          name: "Critical Bugs",
          description: "Number of critical bugs in production",
          unit: "count",
          retentionDays: 365n,
        });
        const metric = expectOk(metricResult);
        const metricId = metric.id;

        const objResult = await actor.addObjective(0n, vsId, {
          name: "Zero Critical Bugs",
          description: ["Maintain zero critical bugs in production"],
          objectiveType: { target: null },
          metricIds: [metricId],
          computation: `metric_${metricId}`,
          target: { count: { target: 0, direction: { decrease: null } } },
          targetDate: [],
        });
        const objective = expectOk(objResult);
        const objId = objective.id;

        // Create a deferred actor for the HTTP outcall test
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask LLM to update the objective with new target
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/tool-call-update-objective",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Update objective ${objId} in value stream ${vsId} to have a target of 2 bugs (count, decrease direction). This is more realistic.`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        expectOk(await result);

        // Verify the update
        actor.setIdentity(adminIdentity);
        const updated = expectOk(await actor.getObjective(0n, vsId, objId));
        expect("count" in updated.target).toBe(true);
        if ("count" in updated.target) {
          expect(updated.target.count.target).toBe(2);
        }
      },
      { timeout: 30000 },
    );

    it(
      "should record objective datapoint",
      async () => {
        // Setup: create value stream, metric, and objective
        actor.setIdentity(adminIdentity);
        const vsResult = await actor.createValueStream(0n, {
          name: "Customer Satisfaction",
          problem: "NPS score declining",
          goal: "Achieve NPS of 50+",
        });
        const valueStream = expectOk(vsResult);
        const vsId = valueStream.id;

        // Activate the value stream
        const activateResult = await actor.updateValueStream(
          0n,
          vsId,
          [],
          [],
          [],
          [{ active: null }],
        );
        expectOk(activateResult);

        const metricResult = await actor.registerMetric({
          name: "Net Promoter Score",
          description: "Customer satisfaction metric",
          unit: "score",
          retentionDays: 365n,
        });
        const metric = expectOk(metricResult);
        const metricId = metric.id;

        const objResult = await actor.addObjective(0n, vsId, {
          name: "NPS Target",
          description: [],
          objectiveType: { target: null },
          metricIds: [metricId],
          computation: `metric_${metricId}`,
          target: { count: { target: 50, direction: { increase: null } } },
          targetDate: [],
        });
        const objective = expectOk(objResult);
        const objId = objective.id;

        // Create a deferred actor for the HTTP outcall test
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask LLM to record a datapoint
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/tool-call-record-datapoint",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Record a datapoint for objective ${objId} in value stream ${vsId}: current NPS is 45.`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        expectOk(await result);

        // Verify the datapoint was recorded
        actor.setIdentity(adminIdentity);
        const updated = expectOk(await actor.getObjective(0n, vsId, objId));
        expect(updated.current.length).toBe(1);
        if (updated.current.length > 0) {
          expect(updated.current[0]).toBeCloseTo(45, 1);
        }
        expect(updated.history.length).toBeGreaterThan(0);
      },
      { timeout: 20000 },
    );

    it(
      "should add impact review to objective",
      async () => {
        // Setup: create value stream, metric, and objective
        actor.setIdentity(adminIdentity);
        const vsResult = await actor.createValueStream(0n, {
          name: "Performance Monitoring",
          problem: "Page load times increasing",
          goal: "Sub-second page loads",
        });
        const valueStream = expectOk(vsResult);
        const vsId = valueStream.id;

        // Activate the value stream
        const activateResult = await actor.updateValueStream(
          0n,
          vsId,
          [],
          [],
          [],
          [{ active: null }],
        );
        expectOk(activateResult);

        const metricResult = await actor.registerMetric({
          name: "Page Load Time",
          description: "Average page load time in milliseconds",
          unit: "ms",
          retentionDays: 90n,
        });
        const metric = expectOk(metricResult);
        const metricId = metric.id;

        const objResult = await actor.addObjective(0n, vsId, {
          name: "Fast Page Loads",
          description: [],
          objectiveType: { target: null },
          metricIds: [metricId],
          computation: `metric_${metricId}`,
          target: { count: { target: 1000, direction: { decrease: null } } },
          targetDate: [],
        });
        const objective = expectOk(objResult);
        const objId = objective.id;

        // Create a deferred actor for the HTTP outcall test
        const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
          idlFactory,
          canisterId,
        );
        deferredActor.setIdentity(adminIdentity);

        // Ask LLM to add an impact review
        const { result } = await withCassette(
          pic,
          "integration-tests/open-org-backend/workspace-admin-talk/tool-call-add-impact-review",
          () =>
            deferredActor.workspaceAdminTalk(
              0n,
              `Add an impact review for objective ${objId} in value stream ${vsId}. The perceived impact is medium, and we should continue monitoring this but it's not critical yet.`,
            ),
          { ticks: 5, maxRounds: 6 },
        );
        expectOk(await result);

        // Verify the impact review was added
        actor.setIdentity(adminIdentity);
        const updated = expectOk(await actor.getObjective(0n, vsId, objId));
        expect(updated.impactReviews.length).toBeGreaterThan(0);
        const review = updated.impactReviews[0];
        expect("medium" in review.perceivedImpact).toBe(true);
      },
      { timeout: 20000 },
    );
  });
});
