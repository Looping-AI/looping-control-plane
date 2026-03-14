#!/usr/bin/env bun

/**
 * Development server startup script
 * Starts the ICP network with proper domain configuration
 */

const ngrokDomain = process.env.NGROK_DEV_DOMAIN;

const args = ["icp", "network", "start", "--clean", "--domain", "localhost"];

// Only add ngrok domain if it's set
if (ngrokDomain && ngrokDomain !== "your_ngrok_dev_domain_here") {
  args.push("--domain", ngrokDomain);
}

console.log("Starting ICP network with:", args.slice(2).join(" "));

const proc = Bun.spawn(args, {
  stdio: ["inherit", "inherit", "inherit"],
  onExit: (proc, exitCode) => {
    process.exit(exitCode ?? 0);
  },
});

// Forward signals
process.on("SIGINT", () => proc.kill());
process.on("SIGTERM", () => proc.kill());

await proc.exited;

export {};
