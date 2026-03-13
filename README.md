# looping-control-plane

The Looping AI Control Plane — an ICP canister that acts as the agentic control layer for the Looping AI platform.

Link for backend with Internet Identity login button working: http://127.0.0.1:4943/?canisterId=uzt4z-lp777-77774-qaabq-cai&id=uxrrr-q7777-77774-qaaaq-cai&ii=http://u6s2n-gx777-77774-qaaba-cai.localhost:4943/

Install Lintoko (https://github.com/caffeinelabs/lintoko) with:
`curl --proto '=https' --tlsv1.2 -LsSf https://github.com/caffeinelabs/lintoko/releases/download/v0.7.0/lintoko-installer.sh | sh`

### Setting Up the Test Environment File

One environment file is required for running tests and is intentionally excluded from version control (see `.gitignore`). This file contains sensitive credentials needed for API testing.

**Creating the .env.test file (for TypeScript tests):**

1. On project root, create a `.env.test` file with the following structure:

   ```
   GROQ_TEST_KEY=your-groq-api-key-here
   ```

2. Replace `your-groq-api-key-here` with your actual [Groq API key](https://console.groq.com/keys).

**Where they're used:**

- The `.env.test` file is loaded by the TypeScript integration and unit tests to provide credentials for testing the canister HTTP Outcalls.

## Read More

[Architecture](ARCHITECTURE.md) with current and planned insights.
