/**
 * Internal Engine — ListWorkflows Integration Tests
 *
 * Verifies the listWorkflows() endpoint:
 *  - Rejects callers that are not coreId (Unauthorized).
 *  - Returns a valid JSON payload with catalogHash and descriptors when
 *    called by coreId.
 *  - catalogHash is a 64-character hex string (SHA-256).
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
import type { InternalEngineService } from "../../setup.ts";
import { createInternalEngineActor } from "../../setup.ts";

// ── Suite ─────────────────────────────────────────────────────────

describe("internal-engine / listWorkflows", () => {
  let pic: PocketIc;
  let engineActor: Actor<InternalEngineService>;
  let coreIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL || "");
    coreIdentity = generateRandomIdentity();
  });

  beforeEach(async () => {
    // Fresh engine canister per test — coreId is baked in at install time.
    const engine = await createInternalEngineActor(
      pic,
      coreIdentity.getPrincipal(),
    );
    engineActor = engine.actor;
    // Default actor identity is anonymous (not coreId).
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  // ── Guard: caller must be coreId ──────────────────────────────

  it("rejects listWorkflows call from non-core principal", async () => {
    // engineActor default identity is anonymous → caller != coreId
    const result = await engineActor.listWorkflows();

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toBe("Unauthorized");
    }
  });

  // ── Happy path ────────────────────────────────────────────────

  it("returns a JSON payload with catalogHash and descriptors for coreId", async () => {
    engineActor.setIdentity(coreIdentity);

    const result = await engineActor.listWorkflows();

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      const parsed = JSON.parse(result.ok) as unknown;
      expect(parsed).toBeObject();

      const catalog = parsed as { catalogHash: string; descriptors: unknown[] };
      expect(typeof catalog.catalogHash).toBe("string");
      expect(Array.isArray(catalog.descriptors)).toBe(true);
    }
  });

  it("catalogHash is a 64-character lowercase hex string", async () => {
    engineActor.setIdentity(coreIdentity);

    const result = await engineActor.listWorkflows();

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      const catalog = JSON.parse(result.ok) as { catalogHash: string };
      expect(catalog.catalogHash).toMatch(/^[0-9a-f]{64}$/);
    }
  });

  it("returns the same catalogHash on repeated calls", async () => {
    engineActor.setIdentity(coreIdentity);

    const first = await engineActor.listWorkflows();
    const second = await engineActor.listWorkflows();

    expect("ok" in first).toBe(true);
    expect("ok" in second).toBe(true);
    if ("ok" in first && "ok" in second) {
      const hash1 = (JSON.parse(first.ok) as { catalogHash: string })
        .catalogHash;
      const hash2 = (JSON.parse(second.ok) as { catalogHash: string })
        .catalogHash;
      expect(hash1).toBe(hash2);
    }
  });

  it("each descriptor has a workflowName field", async () => {
    engineActor.setIdentity(coreIdentity);

    const result = await engineActor.listWorkflows();

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      const catalog = JSON.parse(result.ok) as {
        descriptors: Array<{ workflowName: string }>;
      };
      for (const descriptor of catalog.descriptors) {
        expect(typeof descriptor.workflowName).toBe("string");
      }
    }
  });
});
