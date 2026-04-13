#!/usr/bin/env bun

/**
 * Motoko compiler warning checker.
 *
 * The main build (`moc main.mo`) compiles the whole actor transitively, which
 * suppresses per-module warnings (e.g. M0194 unused identifier). The VS Code
 * Motoko extension catches these by checking each file individually. This
 * script replicates that behavior: it runs `moc --check` on every .mo source
 * file so compiler warnings are surfaced during `bun run lint`.
 */

import { $ } from "bun";
import { join, relative } from "path";
import { readdirSync, statSync } from "fs";

const ROOT = process.cwd();
const SRC_DIR = join(ROOT, "src");

/** Recursively collect all .mo files under a directory. */
function findMoFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      results.push(...findMoFiles(full));
    } else if (entry.endsWith(".mo")) {
      results.push(full);
    }
  }
  return results;
}

async function main() {
  const mocPath = (await $`mops toolchain bin moc`.text()).trim();
  const sourcesRaw = (await $`mops sources`.text()).trim();
  // `mops sources` emits one "--package name path" per line; split into tokens.
  const sourcesArgs = sourcesRaw.split(/\s+/).filter((arg) => arg.length > 0);

  const moFiles = findMoFiles(SRC_DIR);
  console.log(
    `Checking ${moFiles.length} Motoko files for compiler warnings…\n`,
  );

  let totalWarnings = 0;

  for (const file of moFiles) {
    const relPath = relative(ROOT, file);
    const proc = Bun.spawn([mocPath, ...sourcesArgs, "--check", file], {
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;

    // moc writes warnings to stderr
    const stderr = await new Response(proc.stderr).text();
    if (stderr.trim()) {
      console.log(`⚠️  ${relPath}`);
      // Indent each warning line for readability
      for (const line of stderr.trim().split("\n")) {
        console.log(`   ${line}`);
      }
      console.log();
      totalWarnings++;
    }
  }

  if (totalWarnings === 0) {
    console.log("✅ No compiler warnings found.");
  } else {
    console.log(
      `⚠️  Found compiler warnings in ${totalWarnings} file(s). ` +
        `Fix them or prefix unused identifiers with _ to suppress.`,
    );
    process.exit(1);
  }
}

await main();
