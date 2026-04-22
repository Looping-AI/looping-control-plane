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
  "control-plane-core": "\x1b[36m", // cyan
  "internal-engine": "\x1b[34m", // blue
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  red: "\x1b[31m",
  green: "\x1b[32m",
};

type GroupName = "control-plane-core" | "internal-engine";

interface TestGroup {
  name: GroupName;
  args: string[];
}

const TEST_GROUPS: TestGroup[] = [
  {
    name: "control-plane-core",
    args: ["test", "tests/control-plane-core"],
  },
  {
    name: "internal-engine",
    args: ["test", "tests/internal-engine"],
  },
];

const PREFIX_WIDTH = Math.max(...TEST_GROUPS.map((group) => group.name.length));

async function runGroup(
  group: TestGroup,
  env: Record<string, string>,
): Promise<{ name: GroupName; exitCode: number }> {
  const color = COLORS[group.name];
  const prefix = group.name.padEnd(PREFIX_WIDTH);

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
    // Holds an incomplete trailing line carried over from the previous chunk.
    let lineBuffer = "";

    function writeLines(text: string, isLastFlush: boolean) {
      const combined = lineBuffer + text;
      const lines = combined.split("\n");
      // If this is not the final flush, the last element may be an incomplete
      // line — carry it forward. On final flush, write everything.
      lineBuffer = isLastFlush ? "" : (lines.pop() ?? "");
      if (lines.length > 0) {
        const output =
          lines
            .map((line) => `${color}[${prefix}]${COLORS.reset} ${line}`)
            .join("\n") + "\n";
        dest.write(Buffer.from(output));
      }
    }

    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        // Flush the decoder to emit any buffered partial multibyte characters,
        // then write whatever is left in lineBuffer.
        writeLines(decoder.decode(), true);
        break;
      }
      writeLines(decoder.decode(value, { stream: true }), false);
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
