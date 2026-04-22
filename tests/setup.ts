import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  PocketIc,
  generateRandomIdentity,
  SubnetStateType,
  type Actor,
  type DeferredActor,
} from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import type { _SERVICE } from "./builds/control-plane-core.did.d.ts";
import { idlFactory } from "./builds/control-plane-core.did.js";
import type { _SERVICE as TestCanisterService } from "./builds/test-canister.did.d.ts";
import { idlFactory as testCanisterIdlFactory } from "./builds/test-canister.did.js";
import type { InternalEngine as InternalEngineService } from "./builds/internal-engine.did.d.ts";
import { idlFactory as internalEngineIdlFactory } from "./builds/internal-engine.did.js";
import type { StubCoreCanister as StubCoreService } from "./builds/internal-engine-stub-core.did.d.ts";
import { idlFactory as stubCoreIdlFactory } from "./builds/internal-engine-stub-core.did.js";

// Re-export for use with deferred actors
export {
  idlFactory,
  testCanisterIdlFactory,
  internalEngineIdlFactory,
  stubCoreIdlFactory,
};
export type {
  _SERVICE,
  TestCanisterService,
  InternalEngineService,
  StubCoreService,
};

// Test constants for unit tests
export const TEST_API_KEY =
  process.env["OPENROUTER_TEST_KEY"] || "not-needed-due-to-cassette";
export const TEST_MODEL = "openai/gpt-oss-120b";
export const SLACK_TEST_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] || "not-needed-due-to-cassette";
export const SLACK_SIGNING_SECRET =
  process.env["SLACK_APP_SIGNING_SECRET"] || "test-slack-signing-secret-12345";
export const SLACK_ORG_ADMIN_CHANNEL_ID =
  process.env["SLACK_ORG_ADMIN_CHANNEL_ID"] || "C_ORG_ADMIN_NOT_SET";
export const SLACK_SPECS_CHANNEL_ID =
  process.env["SLACK_SPECS_CHANNEL_ID"] || "C_SPECS_NOT_SET";

// Load environment variables from .env.test
const envFile = resolve(import.meta.dir, "..", "..", ".env.test");
try {
  const envContent = await Bun.file(envFile).text();
  envContent.split("\n").forEach((line) => {
    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      const [key, value] = trimmed.split("=");
      if (key && value) {
        process.env[key] = value.replace(/^['"]|['"]$/g, "");
      }
    }
  });
} catch {
  // .env.test file not found, continue without it
}

// Helper to generate valid principals for testing
export function generateTestPrincipal(seed: number): Principal {
  // Create a valid principal from seed
  const bytes = new Uint8Array(29);
  bytes[0] = 0; // Type byte for principal
  bytes.set(new TextEncoder().encode(`test${seed}`), 1);
  return Principal.fromUint8Array(bytes);
}

// Define the path to the canister's WASM file
export const WASM_PATH = resolve(
  import.meta.dir,
  "builds",
  "control-plane-core.wasm",
);

// Define the path to the test canister's WASM file
export const TEST_CANISTER_WASM_PATH = resolve(
  import.meta.dir,
  "builds",
  "test-canister.wasm",
);

// Define the path to the internal-engine WASM files
export const INTERNAL_ENGINE_WASM_PATH = resolve(
  import.meta.dir,
  "builds",
  "internal-engine.wasm",
);

export const INTERNAL_ENGINE_STUB_CORE_WASM_PATH = resolve(
  import.meta.dir,
  "builds",
  "internal-engine-stub-core.wasm",
);

// In-memory WASM cache — loaded once, reused across all tests
let _controlPlaneWasm: Uint8Array | undefined;
let _testCanisterWasm: Uint8Array | undefined;
let _internalEngineWasm: Uint8Array | undefined;
let _stubCoreWasm: Uint8Array | undefined;

function getControlPlaneWasm(): Uint8Array {
  if (!_controlPlaneWasm) {
    _controlPlaneWasm = new Uint8Array(readFileSync(WASM_PATH));
  }
  return _controlPlaneWasm;
}

function getTestCanisterWasm(): Uint8Array {
  if (!_testCanisterWasm) {
    _testCanisterWasm = new Uint8Array(readFileSync(TEST_CANISTER_WASM_PATH));
  }
  return _testCanisterWasm;
}

function getInternalEngineWasm(): Uint8Array {
  if (!_internalEngineWasm) {
    _internalEngineWasm = new Uint8Array(
      readFileSync(INTERNAL_ENGINE_WASM_PATH),
    );
  }
  return _internalEngineWasm;
}

function getStubCoreWasm(): Uint8Array {
  if (!_stubCoreWasm) {
    _stubCoreWasm = new Uint8Array(
      readFileSync(INTERNAL_ENGINE_STUB_CORE_WASM_PATH),
    );
  }
  return _stubCoreWasm;
}

/**
 * Creates a new PocketIC test environment with fiduciary subnet for Schnorr signing
 * and sets up the canister
 * @returns Object with PocketIC instance, actor, canisterId, and controller identity
 */
export async function createBackendCanister(): Promise<{
  pic: PocketIc;
  actor: Actor<_SERVICE>;
  canisterId: import("@icp-sdk/core/principal").Principal;
  controllerIdentity: ReturnType<typeof generateRandomIdentity>;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "", {
    fiduciary: {
      state: { type: SubnetStateType.New },
    },
  });

  // Create controller identity — used as the canister installer (and thus controller)
  const controllerIdentity = generateRandomIdentity();
  const controllerPrincipal = controllerIdentity.getPrincipal();

  const fixture = await pic.setupCanister<_SERVICE>({
    idlFactory,
    wasm: getControlPlaneWasm(),
    sender: controllerPrincipal,
  });

  // Set the controller as the initial actor identity so privileged calls work
  fixture.actor.setIdentity(controllerIdentity);

  return {
    pic,
    actor: fixture.actor,
    canisterId: fixture.canisterId,
    controllerIdentity,
  };
}

/**
 * Creates a new PocketIC test environment with test canister (deferred actor).
 * Use this for tests that require cassette recording/playback.
 * @returns Object with PocketIC instance, deferred test canister actor, and canisterId
 */
export async function createDeferredTestCanister(): Promise<{
  pic: PocketIc;
  actor: DeferredActor<TestCanisterService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "");

  const fixture = await pic.setupCanister<TestCanisterService>({
    idlFactory: testCanisterIdlFactory,
    wasm: getTestCanisterWasm(),
  });

  // Create a deferred actor for cassette recording
  const deferredActor = pic.createDeferredActor<TestCanisterService>(
    testCanisterIdlFactory,
    fixture.canisterId,
  );

  return { pic, actor: deferredActor, canisterId: fixture.canisterId };
}

/**
 * Creates a new PocketIC test environment with test canister (normal actor).
 * Use this for unit tests that don't require cassette recording.
 * @returns Object with PocketIC instance, test canister actor, and canisterId
 */
export async function createTestCanister(): Promise<{
  pic: PocketIc;
  actor: Actor<TestCanisterService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "");

  const fixture = await pic.setupCanister<TestCanisterService>({
    idlFactory: testCanisterIdlFactory,
    wasm: getTestCanisterWasm(),
  });

  return { pic, actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Creates a new PocketIC test environment with test canister and fiduciary subnet.
 * Use this for unit tests that require threshold Schnorr signing (sign_with_schnorr).
 * @returns Object with PocketIC instance, test canister actor, and canisterId
 */
export async function createSchnorrTestCanister(): Promise<{
  pic: PocketIc;
  actor: Actor<TestCanisterService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "", {
    fiduciary: {
      state: { type: SubnetStateType.New },
    },
  });

  const fixture = await pic.setupCanister<TestCanisterService>({
    idlFactory: testCanisterIdlFactory,
    wasm: getTestCanisterWasm(),
  });

  return { pic, actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Creates a fresh backend canister on an existing PocketIc instance.
 * Use in beforeEach to get a clean canister without PocketIc.create() overhead.
 */
export async function freshBackendCanister(
  pic: PocketIc,
  controllerIdentity: ReturnType<typeof generateRandomIdentity>,
): Promise<{
  actor: Actor<_SERVICE>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const fixture = await pic.setupCanister<_SERVICE>({
    idlFactory,
    wasm: getControlPlaneWasm(),
    sender: controllerIdentity.getPrincipal(),
  });
  fixture.actor.setIdentity(controllerIdentity);
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Creates a fresh test canister (normal actor) on an existing PocketIc instance.
 * Use in beforeEach to get a clean canister without PocketIc.create() overhead.
 */
export async function freshTestCanister(pic: PocketIc): Promise<{
  actor: Actor<TestCanisterService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const fixture = await pic.setupCanister<TestCanisterService>({
    idlFactory: testCanisterIdlFactory,
    wasm: getTestCanisterWasm(),
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Creates a fresh test canister (deferred actor) on an existing PocketIc instance.
 * Use in beforeEach for tests that require cassette recording/playback.
 */
export async function freshDeferredTestCanister(pic: PocketIc): Promise<{
  actor: DeferredActor<TestCanisterService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const fixture = await pic.setupCanister<TestCanisterService>({
    idlFactory: testCanisterIdlFactory,
    wasm: getTestCanisterWasm(),
  });
  const deferredActor = pic.createDeferredActor<TestCanisterService>(
    testCanisterIdlFactory,
    fixture.canisterId,
  );
  return { actor: deferredActor, canisterId: fixture.canisterId };
}

// ── Internal Engine helpers ───────────────────────────────────────

/**
 * Deploy the stub-core canister on an existing PocketIc instance.
 * The stub records every `executionApi` call and returns `#ok("{}")`.
 */
export async function createStubCoreActor(pic: PocketIc): Promise<{
  actor: Actor<StubCoreService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const fixture = await pic.setupCanister<StubCoreService>({
    idlFactory: stubCoreIdlFactory,
    wasm: getStubCoreWasm(),
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Deploy the internal-engine canister on an existing PocketIc instance.
 *
 * `coreId` is the principal that becomes the engine's `coreId`.  Any
 * `execute()` call whose `caller != coreId` will be rejected.
 *
 * To allow `execute()` calls from a TypeScript test, create a fake identity
 * whose `getPrincipal()` returns `coreId` and set it on the returned actor:
 *
 * ```ts
 * const fakeCore = { getPrincipal: () => coreId, sign: async () => new ArrayBuffer(64) } as any;
 * engineActor.setIdentity(fakeCore);
 * ```
 *
 * PocketIC does not verify cryptographic signatures, so the noop `sign` is fine.
 */
export async function createInternalEngineActor(
  pic: PocketIc,
  coreId: import("@icp-sdk/core/principal").Principal,
): Promise<{
  actor: Actor<InternalEngineService>;
  canisterId: import("@icp-sdk/core/principal").Principal;
}> {
  const fixture = await pic.setupCanister<InternalEngineService>({
    idlFactory: internalEngineIdlFactory,
    wasm: getInternalEngineWasm(),
    sender: coreId,
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}
