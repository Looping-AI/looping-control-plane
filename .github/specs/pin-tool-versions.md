# Spec: Pin Tool Versions via Root `versions.env`

## Goal

Replace all dynamic/live tool version lookups and scattered hardcoded versions with
a single source of truth at the **repo root**: `versions.env`.

This file is project-level — it matters for local dev, devcontainer, and CI alike —
so it lives at the root where it's immediately visible to anyone working with the repo,
not hidden inside `.github/`.

---

## New File: `versions.env` (repo root)

Create this file at the repo root:

```bash
# Central version pins for all tools used in CI, devcontainer, and local dev.
# Bump versions here; they propagate everywhere automatically.

# DIDC (Candid tool): https://github.com/dfinity/candid/releases
DIDC_VERSION=2025-12-18

# lintoko (Motoko linter): https://github.com/caffeinelabs/lintoko/releases
LINTOKO_VERSION=v0.8.0

# Node.js: https://nodejs.org/en/download/releases/
NODE_VERSION=24

# ICP CLI + ic-wasm: https://www.npmjs.com/package/@icp-sdk/icp-cli
ICP_CLI_VERSION=0.7.0
```

> Note: For ICP_CLI_VERSION, check the current latest on npm before committing
> and pin to the version already in use (run `icp --version` in an existing
> devcontainer or CI log to confirm).

---

## Changes Required

### `.github/workflows/test.yml`

1. Add a step early in the job to load `versions.env` into the GitHub Actions env:

```yaml
- name: Load version pins
  run: cat versions.env >> $GITHUB_ENV
```

Place this step **after** checkout and **before** any setup steps that use the versions.

2. **Setup Node.js** — use the env var:

```yaml
- uses: actions/setup-node@v6
  with:
    node-version: ${{ env.NODE_VERSION }}
```

3. **Setup ICP CLI** — use the env var:

```bash
npm install -g @icp-sdk/icp-cli@${ICP_CLI_VERSION} @icp-sdk/ic-wasm@${ICP_CLI_VERSION}
```

(pin both packages to the same version, or split into separate vars if they diverge)

4. **Setup DIDC** — remove the live GitHub API call; use the env var:

```bash
wget https://github.com/dfinity/candid/releases/download/${DIDC_VERSION}/didc-linux64
sudo mv didc-linux64 /usr/local/bin/didc
sudo chmod +x /usr/local/bin/didc
```

5. **Lint Motoko** — use the env var:

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/caffeinelabs/lintoko/releases/download/${LINTOKO_VERSION}/lintoko-installer.sh | sh
bun run lint
```

### `.github/workflows/copilot-setup-steps.yml`

Same pattern — add the `Load version pins` step after checkout, then use
`${{ env.NODE_VERSION }}`, `${{ env.DIDC_VERSION }}`, and `${{ env.LINTOKO_VERSION }}`
in the respective steps.

### `.github/workflows/dependabot-lockfile.yml`

Same — add `Load version pins` step and use `${{ env.NODE_VERSION }}` for
`setup-node` and `${{ env.LINTOKO_VERSION }}` for the lintoko install step.

### `.devcontainer/setup.sh`

Source `versions.env` from the repo root at the top of the script, after `set -euo pipefail`:

```bash
# Load version pins from repo root
REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../versions.env
source "$REPO_ROOT/versions.env"
```

Then replace all hardcoded version strings with the sourced variables:

- `${DIDC_VERSION}` in the didc install block (remove the live API call)
- `${LINTOKO_VERSION}` in the lintoko install URL
- `${ICP_CLI_VERSION}` in the npm install command
- `${NODE_VERSION}` is handled by the devcontainer feature config, not this script

### `.devcontainer/devcontainer.json`

Update the Node.js devcontainer feature to use `$NODE_VERSION`:

> Note: devcontainer.json does not support shell variable substitution natively.
> Keep `"version": "24"` in devcontainer.json but add a comment referencing
> `versions.env` so it's clear this needs a manual bump alongside the env file.
> A machine-readable sync is out of scope for this task.

---

## Explicitly Out of Scope

- GitHub Actions `uses:` version tags (`@v6`, `@v2`, `@v1`) — these are literal
  strings that cannot be parameterised by the Actions platform. Dependabot already
  manages them automatically via the `github-actions` ecosystem in `dependabot.yml`.
  No change needed.
- `mops.toml` package versions — already documented in `dependabot.yml` as a manual
  concern. Out of scope here.
- `devcontainer.json` Node version — see note above; add a comment, manual bump only.

---

## Acceptance Criteria

- [ ] `versions.env` exists at the repo root with all four version pins and release-page comments.
- [ ] `test.yml` loads `versions.env` into the GitHub Actions env and uses `NODE_VERSION`, `DIDC_VERSION`, `LINTOKO_VERSION`, `ICP_CLI_VERSION` in the relevant steps.
- [ ] `copilot-setup-steps.yml` does the same.
- [ ] `dependabot-lockfile.yml` does the same for `NODE_VERSION` and `LINTOKO_VERSION`.
- [ ] `.devcontainer/setup.sh` sources `versions.env` and uses the variables; the live GitHub API call for DIDC is removed.
- [ ] CI passes on the resulting PR.

---

Read this spec fully and implement it in a new PR.
