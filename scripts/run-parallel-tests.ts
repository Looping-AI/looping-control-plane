#!/usr/bin/env bun

/**
 * Parallel Test Coordinator
 *
 * Starts a single shared PocketIC server, then runs all TypeScript test groups
 * concurrently as child processes — each inheriting the shared PIC_URL.
 * Prefixes every output line with the test group name so interleaved output is readable.
 *
 * Usage:
 *   bun run test:ts-parallel
 */

import { PocketIcServer } from "@dfinity/pic";

// ANSI colours — one per test group
const COLORS = {
  integration: "\x1b[36m", // cyan
  "unit:tools": "\x1b[33m", // yellow
  "unit:not-tools": "\x1b[35m", // magenta
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  red: "\x1b[31m",
  green: "\x1b[32m",
};

type GroupName = "integration" | "unit:tools" | "unit:not-tools";

interface TestGroup {
  name: GroupName;
  args: string[];
}

const TEST_GROUPS: TestGroup[] = [
  {
    name: "integration",
    args: ["test", "tests/integration-tests"],
  },
  {
    name: "unit:tools",
    args: ["test", "tests/unit-tests/control-plane-core/tools"],
  },
  {
    name: "unit:not-tools",
    args: [
      "test",
      "tests/unit-tests",
      "--ignore=tests/unit-tests/control-plane-core/tools",
    ],
  },
];

function prefixLines(text: string, prefix: string, color: string): Uint8Array {
  const lines = text.split("\n");
  // Last element after split on trailing newline is an empty string — skip it.
  const output = lines
    .filter((_, i) => i < lines.length - 1 || lines[i] !== "")
    .map((line) => `${color}[${prefix}]${COLORS.reset} ${line}`)
    .join("\n");
  return Buffer.from(output + "\n");
}

async function runGroup(
  group: TestGroup,
  env: Record<string, string>,
): Promise<{ name: GroupName; exitCode: number }> {
  const color = COLORS[group.name];
  const prefix = group.name.padEnd(14); // align columns

  const proc = Bun.spawn(["bun", ...group.args], {
    env,
    stdout: "pipe",
    stderr: "pipe",
  });

  async function pipeStream(
    stream: ReadableStream<Uint8Array>,
    dest: typeof process.stdout | typeof process.stderr,
  ) {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      dest.write(prefixLines(text, prefix, color));
    }
  }

  await Promise.all([
    pipeStream(proc.stdout, process.stdout),
    pipeStream(proc.stderr, process.stderr),
  ]);

  const exitCode = await proc.exited;
  return { name: group.name, exitCode };
}

async function main() {
  console.log(
    `${COLORS.bold}Starting shared PocketIC server...${COLORS.reset}`,
  );

  const pic = await PocketIcServer.start({
    showRuntimeLogs: true,
    showCanisterLogs: true,
  });

  const picUrl = pic.getUrl();
  console.log(
    `${COLORS.bold}PocketIC server ready at ${picUrl}${COLORS.reset}\n`,
  );

  // Build child env: inherit only defined string values from the current
  // process environment, then inject PIC_URL.
  const childEnv: Record<string, string> = {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        (entry): entry is [string, string] => typeof entry[1] === "string",
      ),
    ),
    PIC_URL: picUrl,
  };

  let results: { name: GroupName; exitCode: number }[] = [];

  try {
    results = await Promise.all(
      TEST_GROUPS.map((group) => runGroup(group, childEnv)),
    );
  } finally {
    console.log(`\n${COLORS.bold}Stopping PocketIC server...${COLORS.reset}`);
    await pic.stop();
  }

  // Print summary
  console.log(`\n${COLORS.bold}=== Test Results ===${COLORS.reset}`);
  let anyFailed = false;
  for (const { name, exitCode } of results) {
    const passed = exitCode === 0;
    const status = passed
      ? `${COLORS.green}PASSED${COLORS.reset}`
      : `${COLORS.red}FAILED (exit ${exitCode})${COLORS.reset}`;
    console.log(`  ${COLORS[name]}[${name}]${COLORS.reset} ${status}`);
    if (!passed) anyFailed = true;
  }
  console.log();

  process.exitCode = anyFailed ? 1 : 0;
  return;
}

main();
