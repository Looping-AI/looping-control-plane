/**
 * Internal Engine — Execute Integration Tests
 *
 * Phase 5 — Synchronous guard rejections and the happy-path #ok return.
 * No LLM calls are made — these tests verify the guards that fire before
 * the zero-delay timer is set.
 *
 * Phase 6 — Async completion path: timer fires, emitComplete reaches stub-core.
 * Requires cassette recording for the LLM HTTP outcall.
 */

import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import { PocketIc, generateRandomIdentity, type Actor } from "@dfinity/pic";
import type { InternalEngineService, StubCoreService } from "../../setup.ts";
import {
  createInternalEngineActor,
  createStubCoreActor,
  TEST_API_KEY,
} from "../../setup.ts";
import type { EnvelopePayload } from "../../builds/internal-engine.did.d.ts";
import { HttpCassette } from "../../lib/cassette.ts";

// ── Helpers ───────────────────────────────────────────────────────

/** Build a minimal valid EnvelopePayload for testing. */
function minimalEnvelope(
  envelopeId: bigint,
  agentName: string,
  prompt: string,
  hash: string[] = [],
): EnvelopePayload {
  return {
    envelopeId,
    requestId: `req-test-${envelopeId}`,
    agentId: 0n,
    workspaceId: 0n,
    workflowName: "wf-test",
    model: "openai/gpt-oss-120b",
    agentName,
    dispatchedVersion: ["v1"],
    instructions: "You are a test assistant.",
    messages: [{ role: { user: null }, content: prompt }],
    constraints: { maxRounds: 3n, maxTokenBudget: [] },
    secrets: { apiKeys: [["openrouter", TEST_API_KEY]] },
    scopeGrants: [],
    catalogHash: hash as [] | [string],
    envelopeNonce: `nonce-${envelopeId}`,
    workflowArguments: [],
  };
}

// ── Suite ─────────────────────────────────────────────────────────

describe("internal-engine / execute", () => {
  let pic: PocketIc;
  let engineActor: Actor<InternalEngineService>;
  let coreIdentity: ReturnType<typeof generateRandomIdentity>;
  let catalogHash = "";

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL || "");
    coreIdentity = generateRandomIdentity();

    // Fetch the catalog hash once — static, derived from the compiled workflow
    // descriptors. Required by execute() since the catalogHash guard was added.
    const tempEngine = await createInternalEngineActor(
      pic,
      coreIdentity.getPrincipal(),
    );
    tempEngine.actor.setIdentity(coreIdentity);
    const catalogResult = await tempEngine.actor.listWorkflows();
    if ("err" in catalogResult) {
      throw new Error(
        `listWorkflows() failed in beforeAll: ${catalogResult.err}`,
      );
    }
    const parsed = JSON.parse(catalogResult.ok) as { catalogHash: string };
    if (!parsed.catalogHash || !/^[0-9a-f]{64}$/i.test(parsed.catalogHash)) {
      throw new Error(
        `Unexpected catalogHash format: "${parsed.catalogHash}". Expected a 64-char hex string.`,
      );
    }
    catalogHash = parsed.catalogHash;
  });

  beforeEach(async () => {
    // Fresh engine canister per test — coreId is baked in at install time.
    const engine = await createInternalEngineActor(
      pic,
      coreIdentity.getPrincipal(),
    );
    engineActor = engine.actor;
    // Default actor identity is anonymous (not coreId).
    // Each test sets the appropriate identity before calling execute().
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  // ── Guard: caller must be coreId ──────────────────────────────

  it("rejects execute call from non-core principal", async () => {
    // engineActor default identity is anonymous → caller != coreId
    const result = await engineActor.execute(
      minimalEnvelope(1n, "test-agent", "Hello"),
    );

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain('"type":"unauthorized"');
    }
  });

  // ── Guard: dispatchedVersion must be "v1" ─────────────────────

  it("rejects envelope with wrong dispatchedVersion", async () => {
    engineActor.setIdentity(coreIdentity);

    const envelope: EnvelopePayload = {
      ...minimalEnvelope(2n, "test-agent", "Hello"),
      dispatchedVersion: ["v99"],
    };

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain("envelopeVersionRequired");
      expect(result.err).toContain("v1");
    }
  });

  it("rejects envelope with null dispatchedVersion", async () => {
    engineActor.setIdentity(coreIdentity);

    const envelope: EnvelopePayload = {
      ...minimalEnvelope(3n, "test-agent", "Hello"),
      dispatchedVersion: [],
    };

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain("envelopeVersionRequired");
    }
  });

  // ── Guard: catalogHash must be present and current ───────────

  it("rejects envelope with missing catalogHash", async () => {
    engineActor.setIdentity(coreIdentity);

    // minimalEnvelope with no hash argument → catalogHash: []
    const envelope = minimalEnvelope(8n, "test-agent", "Hello");

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      const err = JSON.parse(result.err) as { type: string; message: string };
      expect(err.type).toBe("missingCatalogHash");
      expect(typeof err.message).toBe("string");
      expect(err.message.length).toBeGreaterThan(0);
    }
  });

  it("rejects envelope with stale catalogHash", async () => {
    engineActor.setIdentity(coreIdentity);

    // Valid hex shape but deliberately wrong hash value.
    const staleHash = "a".repeat(64);
    const envelope = minimalEnvelope(9n, "test-agent", "Hello", [staleHash]);

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      const err = JSON.parse(result.err) as { type: string; message: string };
      expect(err.type).toBe("staleCatalog");
      expect(typeof err.message).toBe("string");
      expect(err.message.length).toBeGreaterThan(0);
    }
  });

  // ── Guard: openrouter API key must be present ─────────────────

  it("rejects envelope missing openrouter API key", async () => {
    engineActor.setIdentity(coreIdentity);

    const envelope: EnvelopePayload = {
      ...minimalEnvelope(4n, "test-agent", "Hello", [catalogHash]),
      secrets: { apiKeys: [] },
    };

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain("openrouter");
    }
  });

  it("rejects envelope with unrelated API keys but no openrouter key", async () => {
    engineActor.setIdentity(coreIdentity);

    const envelope: EnvelopePayload = {
      ...minimalEnvelope(5n, "test-agent", "Hello", [catalogHash]),
      secrets: { apiKeys: [["some_other_service", "key-value"]] },
    };

    const result = await engineActor.execute(envelope);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain("openrouter");
    }
  });

  // ── Guard: duplicate envelopeId ───────────────────────────────

  it("rejects duplicate envelopeId", async () => {
    engineActor.setIdentity(coreIdentity);

    const envelope = minimalEnvelope(6n, "test-agent", "Hello", [catalogHash]);

    // First call — should succeed
    const first = await engineActor.execute(envelope);
    expect("ok" in first).toBe(true);

    // Second call with the same envelopeId — should be rejected
    const second = await engineActor.execute(envelope);
    expect("err" in second).toBe(true);
    if ("err" in second) {
      expect(second.err).toContain("Duplicate");
      expect(second.err).toContain("6");
    }
  });

  // ── Happy path: synchronous #ok ───────────────────────────────

  it("accepts valid envelope and returns #ok synchronously", async () => {
    engineActor.setIdentity(coreIdentity);

    const result = await engineActor.execute(
      minimalEnvelope(7n, "test-agent", "Hello", [catalogHash]),
    );

    expect("ok" in result).toBe(true);
  });
});

// ── Async completion (Phase 6) ────────────────────────────────────────────────

describe("internal-engine / execute (async completion)", () => {
  let pic: PocketIc;
  let engineActor: Actor<InternalEngineService>;
  let stubActor: Actor<StubCoreService>;
  let catalogHash = "";

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL || "");

    // Deploy stub-core — it becomes the engine's coreId.
    const stub = await createStubCoreActor(pic);
    stubActor = stub.actor;

    // Deploy engine with coreId = stub.canisterId (baked in at install time).
    const engine = await createInternalEngineActor(pic, stub.canisterId);
    engineActor = engine.actor;

    // Spoof identity so execute() sees caller == coreId == stub.canisterId.
    // PocketIC does not verify cryptographic signatures, so a noop sign is fine.
    const fakeCore = {
      getPrincipal: () => stub.canisterId,
      sign: async () => new ArrayBuffer(64),
    } as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    engineActor.setIdentity(fakeCore);

    // Fetch catalog hash — required by execute() after the catalogHash guard was added.
    const catalogResult = await engineActor.listWorkflows();
    if ("err" in catalogResult) {
      throw new Error(
        `listWorkflows() failed in beforeAll: ${catalogResult.err}`,
      );
    }
    const parsed = JSON.parse(catalogResult.ok) as { catalogHash: string };
    if (!parsed.catalogHash || !/^[0-9a-f]{64}$/i.test(parsed.catalogHash)) {
      throw new Error(
        `Unexpected catalogHash format: "${parsed.catalogHash}". Expected a 64-char hex string.`,
      );
    }
    catalogHash = parsed.catalogHash;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("emits completion to core after timer fires (text response)", async () => {
    const cassetteName =
      "internal-engine/integration-tests/execute/text-response";

    await stubActor.clearRecordedCalls();
    const cassette = await HttpCassette.auto(cassetteName);

    const envelope = minimalEnvelope(
      100n,
      "test-agent",
      "Say hello in exactly one word.",
      [catalogHash],
    );

    // Submit envelope — returns #ok synchronously, then zero-delay timer fires.
    const submitResult = await engineActor.execute(envelope);
    expect("ok" in submitResult).toBe(true);

    // Tick to let the timer fire and queue the LLM HTTP outcall.
    await pic.tick(5);

    // Serve the LLM response from the cassette (or record it live).
    await cassette.handleOutcalls(pic);

    // Tick to let the engine process the LLM response and call emitComplete,
    // which makes an inter-canister call to stub-core.
    await pic.tick(5);

    // Save cassette (no-op in playback mode).
    await cassette.save();

    // ── Assertions ──────────────────────────────────────────────────
    const recordedCalls = await stubActor.getRecordedCalls();
    expect(recordedCalls.length).toBeGreaterThan(0);

    const completionCall = recordedCalls.find(
      (c) => c.path === "/workflow/complete",
    );
    expect(completionCall).toBeDefined();
    expect("post" in completionCall!.method).toBe(true);

    const body = JSON.parse(completionCall!.body) as Record<string, unknown>;
    expect(body["envelopeNonce"]).toBe("nonce-100");
    expect(typeof body["humanSummary"]).toBe("string");
    expect((body["humanSummary"] as string).length).toBeGreaterThan(0);
    expect(body["status"]).toBe("completed");
  });

  // ── EnvelopeProcessor: roundLimitReached path ─────────────────

  it("emits roundLimitReached when maxRounds is 0 (no LLM call needed)", async () => {
    // maxRounds = 0 causes the runner's round-limit check to fire immediately
    // before any LLM HTTP call — so no cassette is required.
    await stubActor.clearRecordedCalls();

    const envelope: EnvelopePayload = {
      ...minimalEnvelope(101n, "test-agent", "Will not run", [catalogHash]),
      constraints: { maxRounds: 0n, maxTokenBudget: [] },
    };

    const submitResult = await engineActor.execute(envelope);
    expect("ok" in submitResult).toBe(true);

    // Tick until EnvelopeProcessor.process completes and emitComplete fires.
    // No HTTP outcalls to serve — the round-limit path is purely synchronous
    // inside the runner, so all async boundaries resolve quickly.
    await pic.tick(5);

    // ── Assertions ────────────────────────────────────────────────
    const recordedCalls = await stubActor.getRecordedCalls();

    const completionCall = recordedCalls.find(
      (c) => c.path === "/workflow/complete",
    );
    expect(completionCall).toBeDefined();
    expect("post" in completionCall!.method).toBe(true);

    const body = JSON.parse(completionCall!.body) as Record<string, unknown>;
    expect(body["envelopeNonce"]).toBe("nonce-101");
    expect(body["status"]).toBe("roundLimitReached");
    expect(typeof body["humanSummary"]).toBe("string");
    expect((body["humanSummary"] as string).length).toBeGreaterThan(0);

    // stats object must be present with expected fields
    const stats = body["stats"] as Record<string, unknown>;
    expect(stats).toBeDefined();
    expect(typeof stats["durationNs"]).toBe("number");
    expect(stats["rounds"]).toBe(0);
  });

  // ── Tool routing: catalog workflow dispatches tool to LLM ─────

  it(
    "provides tools to LLM and emits completed when scope grants match",
    async () => {
      const cassetteName =
        "internal-engine/integration-tests/execute/workspace-get-tool-call";

      await stubActor.clearRecordedCalls();
      // Inject a realistic workspace record so the LLM receives meaningful data
      // and can conclude the task with a text response rather than looping.
      await stubActor.setPathResponse(
        "/workspace",
        JSON.stringify({
          id: 1,
          name: "Engineering",
          adminChannelId: "C07ABCDEFGH",
        }),
      );
      const cassette = await HttpCassette.auto(cassetteName);

      const envelope: EnvelopePayload = {
        ...minimalEnvelope(
          200n,
          "test-agent",
          "Get the workspace information.",
          [catalogHash],
        ),
        workflowName: "workspace_get",
        scopeGrants: [{ workspace: { access: { read: null } } }],
        workflowArguments: ['{"action":"get_workspace"}'],
        instructions:
          "You are a workspace management assistant. Use the available tools to fulfil the user's request. When done, report the result.",
      };

      const submitResult = await engineActor.execute(envelope);
      expect("ok" in submitResult).toBe(true);

      // Round 1: timer fires → LLM calls get_workspace tool
      await pic.tick(2);
      await cassette.handleOutcalls(pic);

      // Inter-canister: engine calls stub-core GET /workspace, gets workspace JSON.
      // Round 2: LLM sees the workspace data → may make a follow-up tool call or return text.
      await pic.tick(2);
      await cassette.handleOutcalls(pic);

      // Allow a Round 3 in case the model issues a second tool call before concluding.
      await pic.tick(2);
      await cassette.handleOutcalls(pic);

      // Engine receives text response → emits /workflow/complete to stub-core.
      await pic.tick(2);

      await cassette.save();

      // ── Assertions ──────────────────────────────────────────────────
      const recordedCalls = await stubActor.getRecordedCalls();

      // Tool call: engine called Core's workflowApi for /workspace (GET)
      const toolCall = recordedCalls.find((c) => c.path === "/workspace");
      expect(toolCall).toBeDefined();
      expect("get" in toolCall!.method).toBe(true);

      // Completion: engine emitted completed to Core after the LLM summarised the workspace
      const completionCall = recordedCalls.find(
        (c) => c.path === "/workflow/complete",
      );
      expect(completionCall).toBeDefined();
      const body = JSON.parse(completionCall!.body) as Record<string, unknown>;
      expect(body["envelopeNonce"]).toBe("nonce-200");
      expect(body["status"]).toBe("completed");
    },
    { timeout: 60_000 },
  );
});
