import { resolve } from "node:path";
import {
  PocketIc,
  generateRandomIdentity,
  SubnetStateType,
  type Actor,
} from "@dfinity/pic";
import { Principal } from "@dfinity/principal";
import type { _SERVICE } from "../.dfx/local/canisters/bot-agent-backend/service.did.js";
import { idlFactory } from "../.dfx/local/canisters/bot-agent-backend/service.did.js";

// Re-export for use with deferred actors
export { idlFactory };
export type { _SERVICE };

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
  "..",
  "..",
  ".dfx",
  "local",
  "canisters",
  "bot-agent-backend",
  "bot-agent-backend.wasm",
);

/**
 * Creates a new PocketIC test environment with fiduciary subnet for Schnorr signing
 * and sets up the canister
 * @returns Object with PocketIC instance, actor, and canisterId
 */
export async function createTestEnvironment(): Promise<{
  pic: PocketIc;
  actor: Actor<_SERVICE>;
  canisterId: import("@dfinity/principal").Principal;
}> {
  const pic = await PocketIc.create(process.env.PIC_URL || "", {
    fiduciary: {
      state: { type: SubnetStateType.New },
    },
  });

  const fixture = await pic.setupCanister<_SERVICE>({
    idlFactory,
    wasm: WASM_PATH,
  });

  return { pic, actor: fixture.actor, canisterId: fixture.canisterId };
}

/**
 * Sets up an admin user for testing
 * The first caller automatically becomes admin, then explicitly adds themselves
 * @param actor - The canister actor
 * @returns Object with admin identity and principal
 */
export async function setupAdminUser(actor: Actor<_SERVICE>): Promise<{
  adminIdentity: ReturnType<typeof generateRandomIdentity>;
  adminPrincipal: Principal;
}> {
  const adminIdentity = generateRandomIdentity();
  const adminPrincipal = adminIdentity.getPrincipal();
  actor.setIdentity(adminIdentity);
  await actor.addAdmin(adminPrincipal);
  return { adminIdentity, adminPrincipal };
}

/**
 * Sets up a regular (non-admin) user for testing
 * @param actor - The canister actor
 * @returns Object with user identity and principal
 */
export function setupRegularUser(actor: Actor<_SERVICE>): {
  userIdentity: ReturnType<typeof generateRandomIdentity>;
  userPrincipal: Principal;
} {
  const userIdentity = generateRandomIdentity();
  const userPrincipal = userIdentity.getPrincipal();
  actor.setIdentity(userIdentity);
  return { userIdentity, userPrincipal };
}

/**
 * Creates a test agent with the given parameters
 * Note: Caller must be admin before calling this function
 * @param actor - The canister actor
 * @param name - Agent name
 * @param provider - LLM provider
 * @param model - Model name
 * @returns Agent ID if successful
 * @throws Error if creation fails
 */
export async function createTestAgent(
  actor: Actor<_SERVICE>,
  name: string,
  provider: { openai: null } | { groq: null } | { llmcanister: null },
  model: string,
): Promise<bigint> {
  const result = await actor.createAgent(name, provider, model);
  if ("err" in result) {
    throw new Error(`Failed to create agent: ${result.err}`);
  }
  return result.ok;
}

/**
 * Creates a Groq agent with the API key fetched from .env.test
 * Internally switches to admin identity to create the agent, then to user identity to store the API key
 * @param actor - The canister actor
 * @param adminIdentity - Admin identity for creating the agent
 * @param userIdentity - User identity for storing the API key
 * @param model - Groq model name (default: "llama-3.1-8b-instant")
 * @returns Agent ID if successful
 * @throws Error if creation fails or GROQ_TEST_KEY is not set
 */
export async function createGroqAgent(
  actor: Actor<_SERVICE>,
  adminIdentity: ReturnType<typeof generateRandomIdentity>,
  userIdentity: ReturnType<typeof generateRandomIdentity>,
  model: string = "llama-3.1-8b-instant",
): Promise<bigint> {
  let apiKey = process.env["GROQ_TEST_KEY"];

  // In GitHub CI environment without GROQ_TEST_KEY, use a placeholder
  // (tests will use cassettes and won't make real API calls)
  if (!apiKey) {
    if (process.env["GITHUB_ACTIONS"]) {
      apiKey = "not-needed-due-to-cassette";
    } else {
      throw new Error(
        "GROQ_TEST_KEY environment variable is not set. Please ensure .env.test file exists with GROQ_TEST_KEY defined.",
      );
    }
  }

  // Switch to admin identity to create the agent
  actor.setIdentity(adminIdentity);
  const agentId = await createTestAgent(
    actor,
    "Groq Agent",
    { groq: null },
    model,
  );

  // Switch to user identity to store the API key
  actor.setIdentity(userIdentity);
  await actor.storeApiKey(agentId, { groq: null }, apiKey);

  return agentId;
}
