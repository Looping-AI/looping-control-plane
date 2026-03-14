# Development Scripts

## dev-start.ts

Starts the local ICP network with proper domain configuration and environment variable handling.

### What it does

Launches `icp network start --domain localhost` with domain configuration:

- Always includes `--domain localhost` (required)
- Conditionally adds `--domain <NGROK_DEV_DOMAIN>` if the environment variable is set and not a placeholder value

This script solves the issue of shell variable expansion in package.json scripts by handling the environment variable in TypeScript, ensuring the command doesn't fail when `NGROK_DEV_DOMAIN` is unset.

Starts the network in foreground mode (interactive), use Ctrl+C to stop.

### Usage

```bash
# Using the npm script (recommended)
bun run dev:start

# Or directly
bun run scripts/dev-start.ts
```

### Environment Variables

- `NGROK_DEV_DOMAIN` (optional): Your ngrok domain for external access. If not set or set to the placeholder value `'your_ngrok_dev_domain_here'`, the script will only start with localhost domain.

### Notes

- The script forwards SIGINT and SIGTERM signals to properly shut down the ICP network
- Uses `--clean` flag to start with a fresh state
- Runs the network in the foreground, inheriting stdio for interactive use

### Troubleshooting

**Network fails to start:**

- Ensure no other ICP network instances are running (`icp network stop`)
- Check that ports 4943 and 8000 are available

---

## dev-setup.ts

Automated local ICP development environment setup script.

### What it does

1. **Checks that the local ICP network is running** (you must run `bun run dev:start` first)
2. **Deploys canisters**:
   - `control-plane-core` (with admin principal)
   - `internet_identity`
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
bun run dev:start

# Then in another terminal, run the setup
bun run dev:setup

# Or directly
bun run scripts/dev-setup.ts
```

### Environment Variables

The script reads from `.env` by default. You can copy from `.env.example` file and update with real values:

```env
NGROK_DEV_DOMAIN='your-actual-ngrok-domain.ngrok-free.app'
ADMIN_PRINCIPAL='your-actual-principal-id'
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

- Verify the `ADMIN_PRINCIPAL` is a valid principal ID
- Ensure all Motoko code compiles (`icp build control-plane-core`)

**Secrets fail to store:**

- Check that the canisters are deployed successfully
- Verify the secret values are properly formatted strings
