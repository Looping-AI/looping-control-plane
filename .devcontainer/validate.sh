#!/usr/bin/env bash
set -euo pipefail

# Always stop the network on exit (success or failure)
trap 'icp network stop' EXIT

echo "=== Validating devcontainer environment ==="

echo "[1/3] Starting ICP network..."
icp network start --background

echo "[2/3] Deploying canister (smoke test)..."
icp deploy

echo "[3/3] Running test suite..."
bun run test

echo "=== All checks passed. Environment is healthy. ==="
