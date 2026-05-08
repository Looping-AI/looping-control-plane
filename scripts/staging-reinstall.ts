#!/usr/bin/env bun

/**
 * Staging Reinstall Script
 *
 * Performs a full destructive reinstall of control-plane-core on the staging
 * environment. This clears all canister state. Steps:
 *
 * 1. Build   — compile the latest WASM artifact
 * 2. Stop    — stop the canister so it can be snapshotted
 * 3. Snapshot — take a state snapshot (safety net before wiping)
 * 4. Reinstall — wipe state and install the new WASM
 * 5. Secrets  — re-seed API keys and tokens from .env.staging
 *
 * Usage:
 *   bun run staging:reinstall
 *
 * Prerequisites:
 *   - .env.staging must exist with OPENROUTER_API_KEY, SLACK_APP_SIGNING_SECRET,
 *     and SLACK_APP_BOT_TOKEN populated.
 *   - You must be authenticated with an identity that controls the staging
 *     canister (icp identity default <your-identity>).
 */

import { spawn } from "child_process";
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

const TOTAL_STEPS = 7;
const CANISTER = "control-plane-core";
const ENVIRONMENT = "staging";

function log(message: string, color: string = colors.reset) {
  console.log(`${color}${message}${colors.reset}`);
}

function logStep(step: number, message: string) {
  log(`\n[${step}/${TOTAL_STEPS}] ${message}`, colors.bright + colors.cyan);
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
 * Load environment variables from a given .env file path.
 */
function loadEnvVars(envFileName: string): Record<string, string> {
  try {
    const envPath = resolve(process.cwd(), envFileName);
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
  } catch {
    logError(`Failed to load ${envFileName}`);
    log(
      `  Make sure ${envFileName} exists. You can copy .env.example and fill in staging values.`,
      colors.yellow,
    );
    throw new Error(`Missing ${envFileName}`);
  }
}

/**
 * Execute a command, streaming its output to the console in real time.
 * Resolves when the process exits with code 0; rejects otherwise.
 */
function execCommandStreaming(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "inherit", "inherit"],
    });

    proc.on("close", (code, signal) => {
      if (code === 0) {
        resolve();
      } else if (code !== null) {
        reject(
          new Error(`${command} ${args.join(" ")} exited with code ${code}`),
        );
      } else {
        reject(
          new Error(
            `${command} ${args.join(" ")} was killed by signal ${signal}`,
          ),
        );
      }
    });
  });
}

/**
 * Execute a command and capture its stdout. Used for canister calls where we
 * need to inspect the response.
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

    proc.on("close", (code, signal) => {
      if (code === 0) {
        resolve(stdout);
      } else if (code !== null) {
        reject(new Error(`Command failed with code ${code}: ${stderr}`));
      } else {
        reject(new Error(`Command killed by signal ${signal}: ${stderr}`));
      }
    });
  });
}

/**
 * Store a single secret in the canister via storeOrgCriticalSecrets.
 */
async function storeSecret(
  secretType: string,
  secretValue: string,
): Promise<void> {
  const output = await execCommand("icp", [
    "canister",
    "call",
    CANISTER,
    "storeOrgCriticalSecrets",
    `(variant { ${secretType} }, "${secretValue}")`,
    "-e",
    ENVIRONMENT,
  ]);

  const trimmedOutput = output.trim();
  if (/variant\s*\{\s*err/s.test(trimmedOutput)) {
    const errorMatch = trimmedOutput.match(/err\s*=\s*"([^"]*)"/s);
    const errorMessage = errorMatch ? errorMatch[1] : trimmedOutput;
    throw new Error(`Failed to store secret: ${errorMessage}`);
  }
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

async function stepBuild(): Promise<void> {
  logStep(1, "Building WASM artifact...");
  await execCommandStreaming("icp", ["build", CANISTER]);
  logSuccess("WASM built");
}

async function stepShutdownEngine(): Promise<void> {
  logStep(2, `Shutting down internal engine on ${ENVIRONMENT}...`);

  const output = await execCommand("icp", [
    "canister",
    "call",
    CANISTER,
    "shutdownInternalEngine",
    "()",
    "-e",
    ENVIRONMENT,
  ]);

  const trimmedOutput = output.trim();
  if (/variant\s*\{\s*err/s.test(trimmedOutput)) {
    const errorMatch = trimmedOutput.match(/err\s*=\s*"([^"]*)"/s);
    const errorMessage = errorMatch ? errorMatch[1] : trimmedOutput;
    throw new Error(`Engine shutdown failed: ${errorMessage}`);
  }

  const beforeMatch = trimmedOutput.match(/cyclesBefore\s*=\s*([\d_]+)/);
  const recoveredMatch = trimmedOutput.match(/cyclesRecovered\s*=\s*([\d_]+)/);
  const afterMatch = trimmedOutput.match(/cyclesAfter\s*=\s*([\d_]+)/);
  const before = beforeMatch ? beforeMatch[1].replace(/_/g, "") : "?";
  const recovered = recoveredMatch ? recoveredMatch[1].replace(/_/g, "") : "?";
  const after = afterMatch ? afterMatch[1].replace(/_/g, "") : "?";
  logSuccess(
    `Internal engine shut down | before: ${before} | ~recovered: ${recovered} | after: ${after}`,
  );
}

async function stepStop(): Promise<void> {
  logStep(3, `Stopping ${CANISTER} on ${ENVIRONMENT}...`);
  await execCommandStreaming("icp", [
    "canister",
    "stop",
    CANISTER,
    "-e",
    ENVIRONMENT,
  ]);
  logSuccess(`${CANISTER} stopped`);
}

async function stepSnapshot(): Promise<void> {
  logStep(4, `Taking state snapshot of ${CANISTER} on ${ENVIRONMENT}...`);

  const listOutput = await execCommand("icp", [
    "canister",
    "snapshot",
    "list",
    CANISTER,
    "-e",
    ENVIRONMENT,
  ]);

  // Each snapshot line looks like:
  //   00000000000000030000000001d075910101: 14.75 MiB, taken at ...
  const firstId = listOutput
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /^[0-9a-f]{36}:/.test(line))
    .map((line) => line.split(":")[0])[0];

  const createArgs = [
    "canister",
    "snapshot",
    "create",
    CANISTER,
    "-e",
    ENVIRONMENT,
  ];

  if (firstId) {
    log(`Replacing existing snapshot ${firstId}...`, colors.blue);
    createArgs.push("--replace", firstId);
  }

  await execCommandStreaming("icp", createArgs);
  logSuccess("Snapshot created");
}

async function stepReinstall(): Promise<void> {
  logStep(
    5,
    `Reinstalling ${CANISTER} on ${ENVIRONMENT} (state will be wiped)...`,
  );
  logWarning("This clears all canister state.");
  await execCommandStreaming("icp", [
    "canister",
    "install",
    CANISTER,
    "--mode",
    "reinstall",
    "-e",
    ENVIRONMENT,
    "--yes",
  ]);
  logSuccess(`${CANISTER} reinstalled`);
}

async function stepStart(): Promise<void> {
  logStep(6, `Starting ${CANISTER} on ${ENVIRONMENT}...`);
  await execCommandStreaming("icp", [
    "canister",
    "start",
    CANISTER,
    "-e",
    ENVIRONMENT,
  ]);
  logSuccess(`${CANISTER} started`);
}

async function stepSeedSecrets(envVars: Record<string, string>): Promise<void> {
  logStep(7, "Re-seeding secrets...");

  log("Storing OpenRouter API key...", colors.blue);
  await storeSecret("openRouterApiKey", envVars["OPENROUTER_API_KEY"]);
  logSuccess("OpenRouter API key stored");

  log("Storing Slack signing secret...", colors.blue);
  await storeSecret("slackSigningSecret", envVars["SLACK_APP_SIGNING_SECRET"]);
  logSuccess("Slack signing secret stored");

  log("Storing Slack bot token...", colors.blue);
  await storeSecret("slackBotToken", envVars["SLACK_APP_BOT_TOKEN"]);
  logSuccess("Slack bot token stored");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log("\n" + "=".repeat(80), colors.bright + colors.red);
  log(
    "Staging Reinstall — control-plane-core will be wiped and redeployed",
    colors.bright + colors.red,
  );
  log("=".repeat(80) + "\n", colors.bright + colors.red);

  // Load secrets upfront so we fail fast if the file is missing
  const envVars = loadEnvVars(".env.staging");
  logSuccess("Loaded .env.staging");

  const requiredVars = [
    "OPENROUTER_API_KEY",
    "SLACK_APP_SIGNING_SECRET",
    "SLACK_APP_BOT_TOKEN",
  ];

  const missingVars = requiredVars.filter(
    (varName) => !envVars[varName] || envVars[varName].includes("your_"),
  );

  if (missingVars.length > 0) {
    logError(
      `The following required staging variables are missing or unconfigured: ${missingVars.join(", ")}`,
    );
    log(
      `  Update .env.staging with real values before running this script.`,
      colors.yellow,
    );
    process.exit(1);
  }

  try {
    await stepBuild();
    await stepShutdownEngine();
    await stepStop();
    await stepSnapshot();
    await stepReinstall();
    await stepStart();
    await stepSeedSecrets(envVars);

    log("\n" + "=".repeat(80), colors.bright + colors.green);
    log("✨ Staging reinstall complete.", colors.bright + colors.green);
    log("=".repeat(80) + "\n", colors.bright + colors.green);
  } catch (error) {
    logError(`\nReinstall failed: ${error}`);
    process.exit(1);
  }
}

main();
