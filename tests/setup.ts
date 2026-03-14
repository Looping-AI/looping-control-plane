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

// Re-export for use with deferred actors
export { idlFactory, testCanisterIdlFactory };
export type { _SERVICE, TestCanisterService };

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
    wasm: WASM_PATH,
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
    wasm: TEST_CANISTER_WASM_PATH,
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
    wasm: TEST_CANISTER_WASM_PATH,
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
    wasm: TEST_CANISTER_WASM_PATH,
  });

  return { pic, actor: fixture.actor, canisterId: fixture.canisterId };
}
