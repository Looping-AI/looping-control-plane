import { resolve } from "node:path";
import {
  PocketIc,
  generateRandomIdentity,
  SubnetStateType,
  type Actor,
  type DeferredActor,
} from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import { IDL } from "@icp-sdk/core/candid";
import type { _SERVICE } from "./builds/open-org-backend.did.d.ts";
import { idlFactory } from "./builds/open-org-backend.did.js";
import type { _SERVICE as TestCanisterService } from "./builds/test-canister.did.d.ts";
import { idlFactory as testCanisterIdlFactory } from "./builds/test-canister.did.js";

// Re-export for use with deferred actors
export { idlFactory, testCanisterIdlFactory };
export type { _SERVICE, TestCanisterService };

// Test constants for unit tests
export const TEST_API_KEY =
  process.env["GROQ_TEST_KEY"] || "not-needed-due-to-cassette";
export const TEST_MODEL = "openai/gpt-oss-120b";
export const SLACK_TEST_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] || "not-needed-due-to-cassette";

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
  "open-org-backend.wasm",
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
 * @returns Object with PocketIC instance, actor, canisterId, and owner identity
 */
export async function createTestEnvironment(): Promise<{
  pic: PocketIc;
  actor: Actor<_SERVICE>;
  canisterId: import("@icp-sdk/core/principal").Principal;
  ownerIdentity: ReturnType<typeof generateRandomIdentity>;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "", {
    fiduciary: {
      state: { type: SubnetStateType.New },
    },
  });

  // Create owner identity
  const ownerIdentity = generateRandomIdentity();
  const ownerPrincipal = ownerIdentity.getPrincipal();

  // Encode the owner principal as IDL arguments using the canister's init type
  const args = IDL.encode([IDL.Principal], [ownerPrincipal]);

  const fixture = await pic.setupCanister<_SERVICE>({
    idlFactory,
    wasm: WASM_PATH,
    arg: args,
  });

  // Set the owner as the initial actor identity
  fixture.actor.setIdentity(ownerIdentity);

  return {
    pic,
    actor: fixture.actor,
    canisterId: fixture.canisterId,
    ownerIdentity,
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
 * Sets up a test admin user (non-owner) for testing
 * Only the owner can add admins, so this just creates a new identity
 * and the caller (owner) can add them as an admin if needed
 * @param actor - The canister actor (should be called by owner)
 * @returns Object with admin identity and principal
 */
export async function setupAdminUser(actor: Actor<_SERVICE>): Promise<{
  adminIdentity: ReturnType<typeof generateRandomIdentity>;
  adminPrincipal: Principal;
}> {
  const adminIdentity = generateRandomIdentity();
  const adminPrincipal = adminIdentity.getPrincipal();
  // Owner adds the new admin to workspace 0
  await actor.addWorkspaceAdmin(0n, adminPrincipal);
  return { adminIdentity, adminPrincipal };
}

/**
 * Sets up a regular (non-admin) user for testing
 * @param actor - The canister actor (should be called by owner)
 * @returns Object with user identity and principal
 */
export async function setupRegularUser(actor: Actor<_SERVICE>): Promise<{
  userIdentity: ReturnType<typeof generateRandomIdentity>;
  userPrincipal: Principal;
}> {
  const userIdentity = generateRandomIdentity();
  const userPrincipal = userIdentity.getPrincipal();
  // Owner adds the new user as a member of workspace 0
  await actor.addWorkspaceMember(0n, userPrincipal);
  return { userIdentity, userPrincipal };
}

/**
 * Creates a test agent via the global agent registry.
 * Note: Caller must be admin before calling this function.
 * @param actor - The canister actor
 * @param name - Agent name
 * @param category - Agent category
 * @param secretsAllowed - List of (workspaceId, secretId) pairs this agent may access
 * @returns Registry agent ID if successful
 * @throws Error if creation fails
 */
export async function createTestAgent(
  actor: Actor<_SERVICE>,
  name: string,
  category: { admin: null } | { research: null } | { communication: null },
  secretsAllowed: Array<
    [
      bigint,
      (
        | { groqApiKey: null }
        | { openaiApiKey: null }
        | { slackSigningSecret: null }
        | { slackBotToken: null }
      ),
    ]
  >,
): Promise<bigint> {
  const result = await actor.registerAgent(
    name,
    category,
    { groq: { gpt_oss_120b: null } },
    secretsAllowed,
    [],
    [],
  );
  if ("err" in result) {
    throw new Error(`Failed to register agent: ${result.err}`);
  }
  return result.ok;
}

/**
 * Creates a Groq admin agent in the registry with the API key fetched from .env.test
 * Registration requires OrgAdmin rights; API key storage requires WorkspaceAdmin rights.
 * The API key is stored at workspace level (not per-user).
 * @param actor - The canister actor
 * @param orgAdminIdentity - OrgAdmin (owner) identity used to register the agent
 * @param workspaceAdminIdentity - WorkspaceAdmin identity used to store the API key.
 *   Defaults to orgAdminIdentity when omitted (e.g. when the owner is also a workspace admin).
 * @returns Registry agent ID
 * @throws Error if creation fails or GROQ_TEST_KEY is not set
 */
export async function createGroqAgent(
  actor: Actor<_SERVICE>,
  orgAdminIdentity: ReturnType<typeof generateRandomIdentity>,
  workspaceAdminIdentity: ReturnType<
    typeof generateRandomIdentity
  > = orgAdminIdentity,
): Promise<bigint> {
  const apiKey = TEST_API_KEY;

  // Validate that API key is available
  if (!apiKey || apiKey === "not-needed-due-to-cassette") {
    if (!process.env["GITHUB_ACTIONS"]) {
      throw new Error(
        "GROQ_TEST_KEY environment variable is not set. Please ensure .env.test file exists with GROQ_TEST_KEY defined.",
      );
    }
  }

  // Register the agent as org admin (registerAgent requires #IsOrgAdmin)
  actor.setIdentity(orgAdminIdentity);
  const agentId = await createTestAgent(
    actor,
    "workspace-admin",
    { admin: null },
    [[0n, { groqApiKey: null }]],
  );

  // Store API key at workspace level as workspace admin
  actor.setIdentity(workspaceAdminIdentity);
  await actor.storeSecret(0n, { groqApiKey: null }, apiKey);

  return agentId;
}
