# Spec: Add `.devcontainer` for Agent Codespaces

## Goal

Add a `.devcontainer/devcontainer.json` (and supporting scripts) so any agent running in a GitHub Codespace has a fully working development environment out of the box — no manual setup required.

The codespace should reach a state where:
1. `icp network start` runs without error
2. `icp deploy` succeeds (smoke-tests the ICP CLI + local network)
3. `bun run test` passes

---

## Background

The CI workflow (`.github/workflows/test.yml`) is the reference for what a working environment looks like. The devcontainer must mirror that toolchain exactly so agents and developers get the same environment interactively.

Key tools installed by CI:
- Node.js 24
- Bun (via `oven-sh/setup-bun`)
- `@icp-sdk/icp-cli` and `@icp-sdk/ic-wasm` (npm global)
- `didc` binary (latest release from `dfinity/candid` on GitHub)
- Mops (`ic-mops` npm package)
- `lintoko` (via caffeinelabs installer script)

---

## What to Build

### 1. `.devcontainer/devcontainer.json`

Use the `mcr.microsoft.com/devcontainers/base:ubuntu` base image.

```json
{
  "name": "looping-control-plane",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:1": { "version": "24" },
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "postCreateCommand": "bash .devcontainer/setup.sh",
  "remoteUser": "vscode"
}
```

### 2. `.devcontainer/setup.sh`

Runs once when the codespace is created (`postCreateCommand`). Must be executable (`chmod +x`).

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Looping AI devcontainer setup ==="

# 1. Install Bun
npm install -g bun

# 2. Install ICP CLI tooling
npm install -g @icp-sdk/icp-cli @icp-sdk/ic-wasm

# 3. Install didc (latest release)
VERSION_DIDC=$(curl --silent "https://api.github.com/repos/dfinity/candid/releases/latest" | jq -r '.tag_name')
wget -q "https://github.com/dfinity/candid/releases/download/${VERSION_DIDC}/didc-linux64" -O /tmp/didc
sudo mv /tmp/didc /usr/local/bin/didc
sudo chmod +x /usr/local/bin/didc

# 4. Install Mops
npm install -g ic-mops

# 5. Install lintoko
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/caffeinelabs/lintoko/releases/download/v0.7.0/lintoko-installer.sh | sh

# Ensure ~/.cargo/bin and ~/.local/bin are on PATH for this session
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

# 6. Install project dependencies
bun install --frozen-lockfile
mops install

echo "=== Setup complete ==="
```

> **Important:** Do NOT apply the `sed` patch to `src/control-plane-core/constants.mo`. Local mode is the default; the `#local` → `#test` patch is CI-only.

### 3. `.devcontainer/validate.sh`

A smoke-test script for agents and humans to verify the codespace is healthy. Must be executable (`chmod +x`).

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Validating devcontainer environment ==="

echo "[1/3] Starting ICP network..."
icp network start --background

echo "[2/3] Deploying canister (smoke test)..."
icp deploy

echo "[3/3] Running test suite..."
bun run test

echo "=== All checks passed. Environment is healthy. ==="

icp network stop
```

> `bun run test` runs `test:build`, `test:mops`, `test:integration`, and `test:unit` targets — the same as CI. Integration tests use the local ICP network deployed in step 2. No real Slack/OpenRouter secrets are required.

---

## Validation Steps (for the coding agent)

After creating all files:

1. Confirm `.devcontainer/devcontainer.json` is valid JSON (no trailing commas, correct structure).
2. Confirm `setup.sh` and `validate.sh` have execute permissions (`chmod +x .devcontainer/setup.sh .devcontainer/validate.sh`).
3. Run `bun run format:check` — fix any issues.
4. Run `bun run lint` — fix any issues.
5. Commit all three files and open a **draft PR** targeting `main` with title: `feat: add .devcontainer for agent codespaces`.

---

## Files to Create

```
.devcontainer/
  devcontainer.json
  setup.sh
  validate.sh
```

---

## Out of Scope

- No changes to `.github/workflows/test.yml`
- No secrets baked into devcontainer config — secrets are injected at runtime via Codespaces secrets
- No changes to application source code

---

Read this spec fully and implement it in a new PR.
