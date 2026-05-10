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
import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";

const ROOT = process.cwd();
const SRC_DIR = join(ROOT, "src");
const TESTS_DIR = join(ROOT, "tests");
const CHECK_DIRS = [SRC_DIR, TESTS_DIR];

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

function findAllMoFiles(dirs: string[]): string[] {
  const files = new Set<string>();

  for (const dir of dirs) {
    if (!existsSync(dir)) {
      continue;
    }

    for (const file of findMoFiles(dir)) {
      files.add(file);
    }
  }

  return [...files].sort();
}

async function main() {
  const mocPath = (await $`mops toolchain bin moc`.text()).trim();
  const sourcesRaw = (await $`mops sources`.text()).trim();
  // `mops sources` emits one "--package name path" per line; split into tokens.
  const sourcesArgs = sourcesRaw.split(/\s+/).filter((arg) => arg.length > 0);

  const allFiles = findAllMoFiles(CHECK_DIRS);

  // Check every .mo file individually so that warnings (e.g. M0194 unused
  // identifier) are never suppressed by transitive compilation. Diagnostics
  // are deduplicated by their source location header in case the same warning
  // appears when checking multiple files.
  const seen = new Set<string>();
  const uniqueDiagnostics: string[] = [];

  for (const file of allFiles) {
    const proc = Bun.spawn([mocPath, ...sourcesArgs, "--check", file], {
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;

    // moc writes warnings/errors to stderr
    const stderr = await new Response(proc.stderr).text();
    if (!stderr.trim()) continue;

    // Split stderr into individual diagnostic blocks. Each block starts with
    // a line of the form "path:line.col-line.col: <kind> ...".
    const blocks = stderr
      .trim()
      .split(/(?=^.+:\d+\.\d+-\d+\.\d+:)/m)
      .map((b) => b.trim())
      .filter((b) => b.length > 0);

    for (const block of blocks) {
      // Use the location+header line as the deduplication key.
      const key = block.split("\n")[0].trim();
      if (!seen.has(key)) {
        seen.add(key);
        uniqueDiagnostics.push(block);
      }
    }
  }

  if (uniqueDiagnostics.length === 0) {
    // Silent on success, like other linters
    process.exit(0);
  } else {
    for (const diag of uniqueDiagnostics) {
      console.log(`⚠️`);
      for (const line of diag.split("\n")) {
        console.log(`   ${line}`);
      }
      console.log();
    }
    console.log(
      `⚠️  Found ${uniqueDiagnostics.length} unique diagnostic(s). ` +
        `Fix them or prefix unused identifiers with _ to suppress.`,
    );
    process.exit(1);
  }
}

await main();
