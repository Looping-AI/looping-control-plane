# Spec: Pin Tool Versions in CI and Copilot Setup

## Goal

Replace all dynamic/live tool version lookups in CI workflows with pinned version
constants. Each pinned version must include a comment pointing to where to find
the latest release so it can be manually bumped when needed.

Currently two workflows have this problem:

- `.github/workflows/test.yml` — the main CI workflow
- `.github/workflows/copilot-setup-steps.yml` — the Copilot environment setup

Both share the same setup steps but duplicate them. This spec also introduces a
shared `env` block at the top of each job (or a dedicated setup workflow step) to
define versions in one place per file, with cross-file duplication accepted as a
known trade-off (the two files serve different jobs; keeping them independently
readable is fine).

---

## Affected Tools

### DIDC

Currently: fetches latest release dynamically via GitHub API at CI run time.

Replace with a pinned constant:

```yaml
# Latest release: https://github.com/dfinity/candid/releases
DIDC_VERSION: "2025-12-18"
```

Install using the pinned constant — no curl to the GitHub API.

### lintoko

Currently: hardcoded in the `curl` URL as `v0.8.0` but buried inside the run
script with no comment.

Replace with a pinned constant + comment:

```yaml
# Latest release: https://github.com/caffeinelabs/lintoko/releases
LINTOKO_VERSION: "v0.8.0"
```

Use the constant in the install URL.

---

## Changes Required

### `.github/workflows/test.yml`

1. Add an `env:` block at the **job level** (under `test:`) with the two constants:

```yaml
env:
  # Latest release: https://github.com/dfinity/candid/releases
  DIDC_VERSION: "2025-12-18"
  # Latest release: https://github.com/caffeinelabs/lintoko/releases
  LINTOKO_VERSION: "v0.8.0"
```

2. **Setup DIDC** step — remove the `curl` to the GitHub API; use `$DIDC_VERSION` directly:

```bash
wget https://github.com/dfinity/candid/releases/download/${DIDC_VERSION}/didc-linux64
sudo mv didc-linux64 /usr/local/bin/didc
sudo chmod +x /usr/local/bin/didc
```

3. **Lint Motoko** step — use `$LINTOKO_VERSION`:

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/caffeinelabs/lintoko/releases/download/${LINTOKO_VERSION}/lintoko-installer.sh | sh
bun run lint
```

### `.github/workflows/copilot-setup-steps.yml`

Same pattern — add a job-level `env:` block with the same two constants + comments,
then use them in the respective steps.

---

## Explicitly Out of Scope

- Node.js version (`node-version: 24`) — already pinned via the Action input. No change.
- `setup-bun`, `setup-mops`, `checkout`, `setup-node` — these use Action version tags
  which are already pinned (e.g. `@v2`, `@v6`, `@v1`). Out of scope here.
- Dependabot config — no changes; Dependabot handles npm/Actions version bumps separately.
- ICP-CLI / ic-wasm (`@icp-sdk/icp-cli`, `@icp-sdk/ic-wasm`) — installed via `npm install -g`
  with no version pinned. This is a separate concern; leave for a follow-up task.

---

## Acceptance Criteria

- [ ] `test.yml` has a job-level `env:` block with `DIDC_VERSION` and `LINTOKO_VERSION` — each with a release-page comment.
- [ ] `copilot-setup-steps.yml` has the same `env:` block.
- [ ] The DIDC setup step in both files no longer calls the GitHub API at runtime.
- [ ] The lintoko install step in both files uses `$LINTOKO_VERSION` from the env block.
- [ ] CI passes on the resulting PR.

---

Read this spec fully and implement it in a new PR.
