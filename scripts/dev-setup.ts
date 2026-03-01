#!/usr/bin/env bun

/**
 * Local Development Setup Script
 *
 * This script automates the local ICP development environment setup:
 * 1. Checks that the local dfx network is running (requires: bun run dev:start)
 * 2. Deploys canisters (open-org-backend and internet_identity)
 * 3. Seeds the canister with necessary secrets (Groq API key, Slack credentials)
 * 4. Prints the Candid UI link for easy access
 *
 * Usage:
 *   1. First start the dfx network: bun run dev:start
 *   2. Then run this setup: bun run dev:setup
 *
 * Note: reads from `.env` by default. You can copy from `.env.example` file and update with real values.
 */

import { spawn, spawnSync } from "child_process";
import { readFileSync } from "fs";
import { resolve } from "path";

// ============================================
// Agent Template Types
// ============================================

interface AgentTemplate {
  name: string;
  category: "admin" | "research" | "communication";
  model: {
    provider: "groq";
    variant: string;
  };
  secretsAllowed: Array<{ workspaceId: number; secret: string }>;
  tools: string[];
  sources: string[];
}

function loadAgentTemplate(templateName: string): AgentTemplate {
  const templatePath = resolve(
    process.cwd(),
    "templates",
    "agents",
    `${templateName}.json`,
  );
  const content = readFileSync(templatePath, "utf-8");
  return JSON.parse(content) as AgentTemplate;
}

function buildRegisterAgentArgs(template: AgentTemplate): string {
  const modelCandid = `variant { ${template.model.provider} = variant { ${template.model.variant} } }`;

  const secretsCandid =
    template.secretsAllowed.length === 0
      ? "vec {}"
      : `vec { ${template.secretsAllowed.map((s) => `record { ${s.workspaceId} : nat; variant { ${s.secret} } }`).join("; ")} }`;

  const toolsCandid =
    template.tools.length === 0
      ? "vec {}"
      : `vec { ${template.tools.map((t) => `"${t}"`).join("; ")} }`;

  const sourcesCandid =
    template.sources.length === 0
      ? "vec {}"
      : `vec { ${template.sources.map((s) => `"${s}"`).join("; ")} }`;

  return `("${template.name}", variant { ${template.category} }, ${modelCandid}, ${secretsCandid}, ${toolsCandid}, ${sourcesCandid})`;
}

// ANSI color codes for terminal output
const colors = {
  reset: "\x1b[0m",
  bright: "\x1b[1m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
};

function log(message: string, color: string = colors.reset) {
  console.log(`${color}${message}${colors.reset}`);
}

function logStep(step: number, message: string) {
  log(`\n[${step}/7] ${message}`, colors.bright + colors.cyan);
}

function logSuccess(message: string) {
  log(`✓ ${message}`, colors.green);
}

function logError(message: string) {
  log(`✗ ${message}`, colors.red);
}

function logWarning(message: string) {
  log(`⚠ ${message}`, colors.yellow);
}

/**
 * Load environment variables from .env file
 */
function loadEnvVars(): Record<string, string> {
  try {
    const envPath = resolve(process.cwd(), ".env");
    const envContent = readFileSync(envPath, "utf-8");

    const envVars: Record<string, string> = {};

    envContent.split("\n").forEach((line) => {
      const trimmedLine = line.trim();
      if (trimmedLine && !trimmedLine.startsWith("#")) {
        const match = trimmedLine.match(/^([^=]+)=(.*)$/);
        if (match) {
          const key = match[1].trim();
          let value = match[2].trim();
          // Remove surrounding quotes if present
          value = value.replace(/^['"](.*)['"]$/, "$1");
          envVars[key] = value;
        }
      }
    });

    return envVars;
  } catch (error) {
    logError("Failed to load .env file");
    throw error;
  }
}

/**
 * Execute a shell command and return the result
 */
function execCommand(command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    proc.stdout?.on("data", (data) => {
      stdout += data.toString();
    });

    proc.stderr?.on("data", (data) => {
      stderr += data.toString();
    });

    proc.on("close", (code) => {
      if (code === 0) {
        resolve(stdout);
      } else {
        reject(new Error(`Command failed with code ${code}: ${stderr}`));
      }
    });
  });
}

/**
 * Check if dfx network is already running
 */
function checkDfxNetwork(): void {
  logStep(1, "Checking if dfx network is running...");

  const result = spawnSync("dfx", ["ping", "local"], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.status !== 0) {
    logError("dfx network is not running!");
    log("\nPlease start the dfx network first by running:", colors.yellow);
    log("  bun run dev:start\n", colors.bright + colors.cyan);
    throw new Error("dfx network not running");
  }

  logSuccess("dfx network is running!");
}

/**
 * Get the current dfx identity principal
 */
async function getDfxIdentityPrincipal(): Promise<string> {
  const output = await execCommand("dfx", ["identity", "get-principal"]);
  return output.trim();
}

/**
 * Deploy canisters
 */
async function deployCanisters(deployerPrincipal: string): Promise<void> {
  logStep(2, "Deploying canisters...");

  log("Deploying open-org-backend...", colors.blue);
  await execCommand("dfx", [
    "deploy",
    "--argument",
    `(principal "${deployerPrincipal}")`,
    "open-org-backend",
  ]);
  logSuccess("open-org-backend deployed");

  log("Deploying internet_identity...", colors.blue);
  await execCommand("dfx", ["deploy", "internet_identity"]);
  logSuccess("internet_identity deployed");
}

/**
 * Add an org admin to the canister
 */
async function addOrgAdmin(adminPrincipal: string): Promise<void> {
  logStep(3, "Adding org admin...");

  log(`Adding ${adminPrincipal} as org admin...`, colors.blue);
  await execCommand("dfx", [
    "canister",
    "call",
    "open-org-backend",
    "addOrgAdmin",
    `(principal "${adminPrincipal}")`,
  ]);
  logSuccess("Org admin added");
}

/**
 * Store a secret in the canister
 */
async function storeSecret(
  workspaceId: number,
  secretType: string,
  secretValue: string,
): Promise<void> {
  const output = await execCommand("dfx", [
    "canister",
    "call",
    "open-org-backend",
    "storeSecret",
    `(${workspaceId} : nat, variant { ${secretType} }, "${secretValue}")`,
  ]);

  // Check if the response is an error variant
  const trimmedOutput = output.trim();
  // Use regex to handle newlines between "variant" and "err"
  if (/variant\s*\{\s*err/s.test(trimmedOutput)) {
    // Extract the error message from the response
    const errorMatch = trimmedOutput.match(/err\s*=\s*"([^"]*)"/s);
    const errorMessage = errorMatch ? errorMatch[1] : trimmedOutput;
    throw new Error(`Failed to store secret: ${errorMessage}`);
  }
}

/**
 * Seed the canister with secrets
 */
async function seedSecrets(envVars: Record<string, string>): Promise<void> {
  logStep(4, "Seeding secrets...");

  const workspaceId = 0;

  log("Storing Groq API key...", colors.blue);
  await storeSecret(workspaceId, "groqApiKey", envVars.GROQ_DEV_KEY);
  logSuccess("Groq API key stored");

  log("Storing Slack signing secret...", colors.blue);
  await storeSecret(
    workspaceId,
    "slackSigningSecret",
    envVars.SLACK_APP_SIGNING_SECRET,
  );
  logSuccess("Slack signing secret stored");

  log("Storing Slack bot token...", colors.blue);
  await storeSecret(workspaceId, "slackBotToken", envVars.SLACK_APP_BOT_TOKEN);
  logSuccess("Slack bot token stored");
}

/**
 * Register the default admin agent in the registry
 */
async function registerAdminAgent(): Promise<void> {
  logStep(5, "Registering admin agent...");

  const template = loadAgentTemplate("orgAdmin");
  const candid = buildRegisterAgentArgs(template);

  const output = await execCommand("dfx", [
    "canister",
    "call",
    "open-org-backend",
    "registerAgent",
    candid,
  ]);

  const trimmedOutput = output.trim();
  if (/variant\s*\{\s*err/s.test(trimmedOutput)) {
    const errorMatch = trimmedOutput.match(/err\s*=\s*"([^"]*)"/s);
    const errorMessage = errorMatch ? errorMatch[1] : trimmedOutput;
    // If agent already exists (e.g. re-running setup), treat as non-fatal
    if (errorMessage.includes("already registered")) {
      logWarning(`Admin agent already registered, skipping: ${errorMessage}`);
      return;
    }
    throw new Error(`Failed to register admin agent: ${errorMessage}`);
  }
  logSuccess(
    `Admin agent "${template.name}" registered (${template.model.provider} / ${template.model.variant})`,
  );
}

/**
 * Get canister IDs and construct Candid UI link
 */
async function printCandidUILink(): Promise<void> {
  logStep(6, "Retrieving canister IDs...");

  try {
    const backendId = (
      await execCommand("dfx", ["canister", "id", "open-org-backend"])
    ).trim();
    const internetIdentityId = (
      await execCommand("dfx", ["canister", "id", "internet_identity"])
    ).trim();

    // Get Candid UI canister ID (usually __Candid_UI)
    let candidUiId: string;
    try {
      candidUiId = (
        await execCommand("dfx", ["canister", "id", "__Candid_UI"])
      ).trim();
    } catch {
      // If __Candid_UI doesn't exist, use a default known ID
      logWarning("Could not find __Candid_UI canister, using default ID");
      candidUiId = "bd3sg-teaaa-aaaaa-qaaba-cai";
    }

    logStep(7, "Setup complete!");

    log("\n" + "=".repeat(80), colors.bright);
    log("Candid UI Links:", colors.bright + colors.green);
    log("=".repeat(80), colors.bright);

    const candidUrl = `http://127.0.0.1:4943/?canisterId=${candidUiId}&id=${backendId}`;
    const candidUrlWithII = `${candidUrl}&ii=http://${internetIdentityId}.localhost:4943/`;

    log(`\nWith Internet Identity:`, colors.cyan);
    log(candidUrlWithII, colors.blue);

    log("\n" + "=".repeat(80), colors.bright);
    log("\nCanister IDs:", colors.bright);
    log(`  open-org-backend:    ${backendId}`, colors.blue);
    log(`  internet_identity:   ${internetIdentityId}`, colors.blue);
    log(`  __Candid_UI:         ${candidUiId}`, colors.blue);
    log("=".repeat(80) + "\n", colors.bright);
  } catch (error) {
    logError(`Failed to retrieve canister IDs: ${error}`);
  }
}

/**
 * Main execution function
 */
async function main() {
  log("\n" + "=".repeat(80), colors.bright + colors.green);
  log("Local ICP Development Environment Setup", colors.bright + colors.green);
  log("=".repeat(80) + "\n", colors.bright + colors.green);

  try {
    // Load environment variables
    const envVars = loadEnvVars();
    logSuccess("Loaded environment variables from .env");

    // Validate required environment variables
    const requiredVars = [
      "NGROK_DEV_DOMAIN",
      "ADMIN_PRINCIPAL",
      "GROQ_DEV_KEY",
      "SLACK_APP_SIGNING_SECRET",
      "SLACK_APP_BOT_TOKEN",
    ];

    const missingVars = requiredVars.filter(
      (varName) => !envVars[varName] || envVars[varName].includes("your_"),
    );

    if (missingVars.length > 0) {
      logWarning(
        `The following environment variables are not yet configured: ${missingVars.join(", ")}`,
      );
    }

    // Check if dfx network is running
    checkDfxNetwork();

    // Get the current dfx identity principal (for deployment)
    const dfxPrincipal = await getDfxIdentityPrincipal();
    log(`Using dfx identity: ${dfxPrincipal}`, colors.blue);

    // Deploy canisters
    await deployCanisters(dfxPrincipal);

    // Add the admin principal as org admin
    await addOrgAdmin(envVars.ADMIN_PRINCIPAL);

    // Seed secrets
    await seedSecrets(envVars);

    // Register admin agent
    await registerAdminAgent();

    // Print Candid UI link
    await printCandidUILink();

    logSuccess("\n✨ All done! Your local environment is ready.\n");
  } catch (error) {
    logError(`\nSetup failed: ${error}`);
    process.exit(1);
  }
}

// Run the script
main().catch((error) => {
  logError(`Unhandled error: ${error}`);
  process.exit(1);
});
