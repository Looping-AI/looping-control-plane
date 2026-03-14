#!/usr/bin/env bun

import { $ } from "bun";
import { join, relative } from "path";

/**
 * Build script for Motoko files
 * Compiles test-canister.mo and control-plane-core.mo using mops toolchain and generates Candid interfaces
 */

// Configuration for different build targets
const BUILD_TARGETS = {
  test: {
    name: "test canister",
    sourceFile: join(
      process.cwd(),
      "tests",
      "unit-tests",
      "control-plane-core",
      "test-canister.mo",
    ),
    outputPrefix: "test-canister",
  },
  "control-plane-core": {
    name: "control-plane-core canister",
    sourceFile: join(process.cwd(), "src", "control-plane-core", "main.mo"),
    outputPrefix: "control-plane-core",
  },
} as const;

/**
 * Common build environment setup
 */
async function getBuildEnvironment() {
  const mocPath = await $`mops toolchain bin moc`.text();
  const sources = await $`mops sources`.text();
  const outputDir = join(process.cwd(), "tests", "builds");

  await $`mkdir -p ${outputDir}`;

  return {
    mocPath: mocPath.trim(),
    sourcesArgs: sources
      .trim()
      .split(/\s+/)
      .filter((arg) => arg.length > 0),
    outputDir,
  };
}

/**
 * Compile a Motoko file to WASM
 */
async function compileToWasm(target: keyof typeof BUILD_TARGETS) {
  try {
    const config = BUILD_TARGETS[target];
    const { mocPath, sourcesArgs, outputDir } = await getBuildEnvironment();
    const outputFile = join(outputDir, `${config.outputPrefix}.wasm`);

    const args = [mocPath, ...sourcesArgs, "-o", outputFile, config.sourceFile];

    console.log(`Building ${config.name}...`);
    await $`${args}`.env({ ...process.env });

    // Gzip-compress the WASM in place. ICP natively accepts gzip-compressed
    // WASMs, and this keeps the file well under PocketIC's 2 MB ingress limit.
    console.log(`🗜️ ${config.name} built successfully, gzip-compressing...`);
    const gzipped = new Uint8Array(
      await $`gzip -c ${outputFile}`.arrayBuffer(),
    );
    await Bun.write(outputFile, gzipped);

    console.log(
      `✅ ${config.name} build completed successfully (gzip-compressed)`,
    );
  } catch (error) {
    console.error(`❌ Failed to build ${BUILD_TARGETS[target].name}:`);
    console.error(error);
    process.exit(1);
  }
}

/**
 * Generate Candid interface and TypeScript bindings
 */
async function generateCandidInterface(target: keyof typeof BUILD_TARGETS) {
  try {
    const config = BUILD_TARGETS[target];
    const { mocPath, sourcesArgs, outputDir } = await getBuildEnvironment();
    const candidFile = join(outputDir, `${config.outputPrefix}.did`);
    const tsBindingsFile = join(outputDir, `${config.outputPrefix}.did.d.ts`);
    const jsBindingsFile = join(outputDir, `${config.outputPrefix}.did.js`);

    console.log(`Generating ${config.name} Candid interface...`);

    // Generate .did file
    const candidArgs = [
      mocPath,
      ...sourcesArgs,
      "--idl",
      config.sourceFile,
      "-o",
      candidFile,
    ];
    await $`${candidArgs}`.env({ ...process.env });
    console.log(
      `✅ Generated Candid interface: ${relative(process.cwd(), candidFile)}`,
    );

    // Generate TypeScript bindings
    console.log(`Generating ${config.name} TypeScript bindings...`);
    await $`didc bind ${candidFile} -t ts > ${tsBindingsFile}`.env({
      ...process.env,
    });
    await $`didc bind ${candidFile} -t js > ${jsBindingsFile}`.env({
      ...process.env,
    });

    // TODO: remove this step when dfx is replaced with icp-cli
    // didc generates imports from @dfinity/* packages, but @dfinity/pic 0.18+
    // uses @icp-sdk/core/* for Principal/IDL/ActorMethod. Rewrite the imports
    // so TypeScript doesn't see two structurally-incompatible versions of the same type.
    let tsContent = await Bun.file(tsBindingsFile).text();
    tsContent = tsContent
      .replace(/from '@dfinity\/principal'/g, "from '@icp-sdk/core/principal'")
      .replace(/from '@dfinity\/agent'/g, "from '@icp-sdk/core/agent'")
      .replace(/from '@dfinity\/candid'/g, "from '@icp-sdk/core/candid'");
    await Bun.write(tsBindingsFile, tsContent);

    console.log(
      `✅ Generated TypeScript and Javascript bindings:\n` +
        `  TypeScript: ${relative(process.cwd(), tsBindingsFile)}\n` +
        `  Javascript: ${relative(process.cwd(), jsBindingsFile)}`,
    );
  } catch (error) {
    console.error(
      `❌ Failed to generate ${BUILD_TARGETS[target].name} Candid interface:`,
    );
    console.error(error);
    process.exit(1);
  }
}

/**
 * Build a complete target (WASM + Candid)
 */
async function buildTarget(target: keyof typeof BUILD_TARGETS) {
  await compileToWasm(target);
  await generateCandidInterface(target);
}

// Public API functions for backward compatibility
export const buildTestCanister = () => compileToWasm("test");
export const buildControlPlaneCoreCanister = () =>
  compileToWasm("control-plane-core");
export const generateTestCandidInterface = () =>
  generateCandidInterface("test");
export const generateControlPlaneCoreCandidInterface = () =>
  generateCandidInterface("control-plane-core");

/**
 * Complete build process: compiles both test and main canisters and generates Candid interfaces
 */
export async function buildAll() {
  console.log("🚀 Starting complete build process...\n");

  await buildTarget("test");
  console.log();

  await buildTarget("control-plane-core");
  console.log();

  console.log("🎉 Complete build process finished successfully!");
}

// Run the build if this script is executed directly
if (import.meta.main) {
  await buildAll();
}
