# Development Scripts

## dev-setup.ts

Automated local ICP development environment setup script.

### What it does

1. **Checks that the local ICP network is running** (you must run `icp network start` first)
2. **Deploys canisters**:
   - `control-plane-core`
3. **Seeds secrets** into the canister:
   - OpenRouter API key
   - Slack signing secret
   - Slack bot token
4. **Prints Candid UI links** for easy access to the canister interface

### Prerequisites

Before running the script, ensure you have:

- The local ICP network running (see `dev-start.ts` above)
- `bun` installed
- A `.env` file with your actual configuration values (copy from `.env.example`)

### Usage

```bash
# First, start the ICP network
icp network start

# Then in another terminal, run the setup
bun run dev:setup

# Or directly
bun run scripts/dev-setup.ts
```

### Environment Variables

The script reads from `.env` by default. You can copy from `.env.example` file and update with real values:

```env
OPENROUTER_DEV_KEY='sk-or-your_actual_openrouter_api_key'
SLACK_APP_SIGNING_SECRET='your_actual_slack_signing_secret'
SLACK_APP_BOT_TOKEN='xoxb-your-actual-bot-token'
```

### Output

When successful, the script will:

- Display progress for each step with colored output
- Show the Candid UI links for accessing your canisters
- Display all deployed canister IDs

### Troubleshooting

**Deployment fails:**

- Ensure all Motoko code compiles (`icp build control-plane-core`)

**Secrets fail to store:**

- Check that the canisters are deployed successfully
- Verify the secret values are properly formatted strings

---

## staging-reinstall.ts

Destructive reinstall of `control-plane-core` on the `staging` environment. Wipes
all canister state, installs the latest WASM, and re-seeds credentials.

> **Warning:** This script is irreversible beyond the snapshot it creates. Only run
> it when you intentionally want to reset staging state.

### What it does

1. **Builds** the latest WASM artifact (`icp build control-plane-core`)
2. **Stops** the canister on staging (`icp canister stop`)
3. **Snapshots** the current state as a safety net (`icp canister snapshot create`)
4. **Reinstalls** with `--mode reinstall`, wiping all state (`icp canister install`)
5. **Starts** the canister again (`icp canister start`)
6. **Re-seeds secrets** from `.env.staging`:
   - OpenRouter API key
   - Slack signing secret
   - Slack bot token

### Prerequisites

- A `.env.staging` file with real credentials (not placeholder values):

  ```env
  OPENROUTER_API_KEY='sk-or-your_actual_key'
  SLACK_APP_SIGNING_SECRET='your_actual_signing_secret'
  SLACK_APP_BOT_TOKEN='xoxb-your-actual-bot-token'
  ```

- Your `icp` identity must control the `control-plane-core` canister on staging.
  Check with `icp identity default` and switch if needed:

  ```bash
  icp identity default my-staging-identity
  ```

### Usage

```bash
bun run staging:reinstall

# Or directly
bun run scripts/staging-reinstall.ts
```

### Error handling

The script fails fast:

- If `.env.staging` is missing or any required variable is not populated, it exits
  before touching the canister.
- If any `icp` command exits with a non-zero code or is killed by a signal, the
  script prints the error and exits immediately. Subsequent steps are not run.

### Troubleshooting

**`icp canister stop` fails:**

- The canister may already be stopped. You can re-run or manually start from step 4
  (`icp canister install control-plane-core --mode reinstall -e staging --yes`).

**`icp canister snapshot create` fails:**

- Snapshots require the canister to be stopped first.
- Ensure your identity has controller rights on the canister.

**Secrets fail to store after reinstall:**

- The canister must be in a running state before `storeOrgCriticalSecrets` can be
  called. If reinstall succeeded but the canister did not start automatically,
  run: `icp canister start control-plane-core -e staging`.
