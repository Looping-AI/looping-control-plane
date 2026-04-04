#!/usr/bin/env bash
set -euo pipefail

# Load version pins from repo root
REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../versions.env
source "$REPO_ROOT/versions.env"

echo "=== Looping AI devcontainer setup ==="

# 1. Install system dependencies required by this script
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq wget

# 2. Install Bun (match CI's oven-sh/setup-bun by using the official installer)
curl -fsSL https://bun.sh/install | bash

# Persist PATH update for future shells (lintoko also installs here)
PATH_EXPORT='export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"'
if ! grep -qs '.bun/bin' "$HOME/.profile" 2>/dev/null; then
  echo "$PATH_EXPORT" >> "$HOME/.profile"
fi
if ! grep -qs '.bun/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo "$PATH_EXPORT" >> "$HOME/.bashrc"
fi
# Apply to current session
eval "$PATH_EXPORT"

# 3. Install ICP CLI tooling
npm install -g @icp-sdk/icp-cli@${ICP_CLI_VERSION} @icp-sdk/ic-wasm@${IC_WASM_VERSION}

# 4. Install didc (pinned release)
wget -q "https://github.com/dfinity/candid/releases/download/${DIDC_VERSION}/didc-linux64" -O /tmp/didc
sudo mv /tmp/didc /usr/local/bin/didc
sudo chmod +x /usr/local/bin/didc

# 5. Install Mops (matches CI's dfinity/setup-mops@v1)
npm install -g ic-mops

# 6. Install lintoko
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/caffeinelabs/lintoko/releases/download/${LINTOKO_VERSION}/lintoko-installer.sh | sh

# 7. Install project dependencies
bun install --frozen-lockfile
mops install

echo "=== Setup complete ==="
