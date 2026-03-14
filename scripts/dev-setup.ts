#!/usr/bin/env bun

/**
 * Local Development Setup Script
 *
 * This script automates the local ICP development environment setup:
 * 1. Checks that the local network is running (requires: `icp network start`)
 * 2. Deploys canisters (control-plane-core)
 * 3. Seeds the canister with necessary secrets (OpenRouter API key, Slack credentials)
 * 4. Prints the Candid UI link for easy access
 *
 * Usage:
 *   1. First start the ICP network: icp network start
 *   2. Then run this setup: bun run dev:setup
 *
 * Note: reads from `.env` by default. You can copy from `.env.example` file and update with real values.
 */

import { spawn, spawnSync } from "child_process";
import { readFileSync } from "fs";
import { resolve } from "path";

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
  log(`\n[${step}/4] ${message}`, colors.bright + colors.cyan);
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
 * Check if ICP network is already running
 */
function checkIcpNetwork(): void {
  logStep(1, "Checking if ICP network is running...");

  const result = spawnSync("icp", ["network", "ping"], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.status !== 0) {
    logError("ICP network is not running!");
    log("\nPlease start the ICP network first by running:", colors.yellow);
    log("  icp network start\n", colors.bright + colors.cyan);
    throw new Error("ICP network not running");
  }

  logSuccess("ICP network is running!");
}

/**
 * Deploy canisters
 */
async function deployCanisters(): Promise<void> {
  logStep(2, "Deploying canisters...");

  log("Deploying control-plane-core...", colors.blue);
  await execCommand("icp", ["deploy", "control-plane-core"]);
  logSuccess("control-plane-core deployed");
}

/**
 * Store a secret in the canister
 */
async function storeSecret(
  secretType: string,
  secretValue: string,
): Promise<void> {
  const output = await execCommand("icp", [
    "canister",
    "call",
    "control-plane-core",
    "storeOrgCriticalSecrets",
    `(variant { ${secretType} }, "${secretValue}")`,
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
  logStep(3, "Seeding secrets...");

  log("Storing OpenRouter API key...", colors.blue);
  await storeSecret("openRouterApiKey", envVars.OPENROUTER_DEV_KEY);
  logSuccess("OpenRouter API key stored");

  log("Storing Slack signing secret...", colors.blue);
  await storeSecret("slackSigningSecret", envVars.SLACK_APP_SIGNING_SECRET);
  logSuccess("Slack signing secret stored");

  log("Storing Slack bot token...", colors.blue);
  await storeSecret("slackBotToken", envVars.SLACK_APP_BOT_TOKEN);
  logSuccess("Slack bot token stored");
}

/**
 * Get canister IDs and construct Candid UI link
 */
async function printCandidUILink(): Promise<void> {
  logStep(4, "Retrieving canister IDs...");

  try {
    const statusOutput = await execCommand("icp", [
      "canister",
      "status",
      "control-plane-core",
    ]);
    const canisterIdMatch = statusOutput.match(/Canister Id:\s*([a-z0-9-]+)/);
    if (!canisterIdMatch || !canisterIdMatch[1]) {
      throw new Error(
        "Could not extract canister ID from canister status output",
      );
    }
    const backendId = canisterIdMatch[1];

    // Get Candid UI canister ID from network status
    let candidUiId: string;
    try {
      const statusOutput = await execCommand("icp", ["network", "status"]);
      const candidUiMatch = statusOutput.match(
        /Candid UI Principal:\s*([a-z0-9-]+)/,
      );
      if (candidUiMatch && candidUiMatch[1]) {
        candidUiId = candidUiMatch[1];
      } else {
        throw new Error(
          "Could not extract Candid UI Principal from network status",
        );
      }
    } catch {
      // Fallback to default known ID
      logWarning("Could not find Candid UI Principal, using default ID");
      candidUiId = "tqzl2-p7777-77776-aaaaa-cai";
    }

    logStep(4, "Setup complete!");

    log("\n" + "=".repeat(80), colors.bright);
    log("Candid UI Links:", colors.bright + colors.green);
    log("=".repeat(80), colors.bright);

    const candidUrl = `http://127.0.0.1:8000/?canisterId=${candidUiId}&id=${backendId}`;
    const internetIdentityId = "rdmx6-jaaaa-aaaaa-aaadq-cai"; // Default Internet Identity canister ID in local ICP
    const candidUrlWithII = `${candidUrl}&ii=http://${internetIdentityId}.localhost:8000/`;

    log(`\nWith Internet Identity:`, colors.cyan);
    log(candidUrlWithII, colors.blue);

    log("\n" + "=".repeat(80), colors.bright);
    log("\nCanister IDs:", colors.bright);
    log(`  control-plane-core:  ${backendId}`, colors.blue);
    log(`  Internet_Identity:   ${internetIdentityId}`, colors.blue);
    log(`  Candid_UI:           ${candidUiId}`, colors.blue);
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
      "OPENROUTER_DEV_KEY",
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

    // Check if ICP network is running
    checkIcpNetwork();

    // Deploy canisters
    await deployCanisters();

    // Seed secrets
    await seedSecrets(envVars);

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
