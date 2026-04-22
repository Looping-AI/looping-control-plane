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
import { readFileSync, readdirSync, statSync } from "fs";
import { dirname, join, normalize } from "path";

const ROOT = process.cwd();
const SRC_DIR = join(ROOT, "src");
const IMPORT_PATTERN = /^\s*import\b.*"([^"]+)";\s*$/gm;

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

function findLocalDependencies(
  file: string,
  knownFiles: Set<string>,
): string[] {
  const source = readFileSync(file, "utf8");
  const dependencies = new Set<string>();

  for (const match of source.matchAll(IMPORT_PATTERN)) {
    const specifier = match[1];
    if (!specifier.startsWith("./") && !specifier.startsWith("../")) {
      continue;
    }

    const resolved = normalize(
      join(
        dirname(file),
        specifier.endsWith(".mo") ? specifier : `${specifier}.mo`,
      ),
    );

    if (knownFiles.has(resolved)) {
      dependencies.add(resolved);
    }
  }

  return [...dependencies];
}

function findCheckRoots(moFiles: string[]): string[] {
  const normalizedFiles = moFiles.map((file) => normalize(file));
  const knownFiles = new Set(normalizedFiles);
  const incomingEdges = new Map<string, number>();

  for (const file of normalizedFiles) {
    incomingEdges.set(file, 0);
  }

  for (const file of normalizedFiles) {
    for (const dependency of findLocalDependencies(file, knownFiles)) {
      incomingEdges.set(dependency, (incomingEdges.get(dependency) ?? 0) + 1);
    }
  }

  return normalizedFiles
    .filter((file) => (incomingEdges.get(file) ?? 0) === 0)
    .sort();
}

async function main() {
  const mocPath = (await $`mops toolchain bin moc`.text()).trim();
  const sourcesRaw = (await $`mops sources`.text()).trim();
  // `mops sources` emits one "--package name path" per line; split into tokens.
  const sourcesArgs = sourcesRaw.split(/\s+/).filter((arg) => arg.length > 0);

  const moFiles = findMoFiles(SRC_DIR).sort();
  const rootFiles = findCheckRoots(moFiles);
  console.log(
    `Checking ${rootFiles.length} Motoko root files for compiler warnings ` +
      `(covering ${moFiles.length} source files)…\n`,
  );

  // Root-only checks avoid re-checking files that are already compiled via a
  // local importer. Shared dependencies can still appear under multiple roots,
  // so diagnostics are deduplicated by their source location header.
  const seen = new Set<string>();
  const uniqueDiagnostics: string[] = [];

  for (const file of rootFiles) {
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
    console.log("✅ No compiler warnings found.");
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
