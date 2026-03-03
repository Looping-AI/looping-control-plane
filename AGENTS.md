# AGENTS Instructions

## Project Overview

This is an **ICP (Internet Computer Protocol)** decentralized application built with:

- **Motoko** for smart contract backend (`src/open-org-backend/`)
- **TypeScript** for tests (`tests/`) using PocketIC for local testing
- **Bun** as the package manager and runtime

## Important: Package Manager

**Use `bun` commands only.** Do NOT use `npm` or `npx` commands.

Examples:

- `bun install` - Install dependencies
- `bun run <script>` - Run scripts from package.json
- `bun run test` - Run full tests flow
- `bun run test:build` - Rebuild canisters when src code modified
- `bun run test:unit` - Run unit tests
- `bun run test:integration` - Run integration tests
- `bun run format` - Run code formatter
- `bun run lint` - Run linter

### Running Specific Tests

**IMPORTANT:** To run specific test files or individual tests, use `bun test` directly (NOT `bun run test`).

The `bun run test` script runs a complete build and test suite and does NOT accept additional parameters.

Examples:

```bash
# Run a specific test file
bun test tests/integration-tests/open-org-backend/workspace-admin-talk.spec.ts

# Run a specific test case by name (using -t flag)
bun test tests/integration-tests/open-org-backend/workspace-admin-talk.spec.ts -t "should accept message from workspace admin"

# Record cassettes for a specific test file
RECORD_CASSETTES=true bun test tests/integration-tests/open-org-backend/workspace-admin-talk.spec.ts
```

## Library Dependencies

### mo:base is Deprecated - Use mo:core

**NEVER use `mo:base`** - it is deprecated and unmaintained. Use **`mo:core`** instead.

- `mo:core` is the modern successor to `mo:base`.
- All standard modules are available in `mo:core` (Array, Blob, Principal, Timer, Text, etc.)
- If you encounter compatibility issues, check the module definitions in `.mops/core@{version}/src/` for the correct API

## When to Request Feedback (CRITICAL)

**STOP and REQUEST USER FEEDBACK** before proceeding in these situations:

### Design Decision Blockers

- **Feature removal or significant reduction in scope** (e.g., removing web search capability, disabling a planned feature)
- **Architecture changes** that affect multiple files or core patterns
- **API contract changes** that impact external integrations or user-facing behavior
- **Performance trade-offs** where there are multiple valid approaches with different costs
- **Security or privacy implications** (encryption, authentication, data access)

### Technical Blockers

- **Multiple solution paths exist** with unclear "best" choice
- **External dependency limitations** (API doesn't support intended feature, library missing capability)
- **Breaking changes required** to existing tests or production code
- **Workarounds needed** that compromise original requirements

### How to Request Feedback

When you encounter a blocking decision:

1. **Stop immediately** - do not implement a solution
2. **Explain the situation**: What you discovered, why it's blocking progress
3. **Present options**: List 2-3 alternatives with pros/cons for each
4. **Recommend approach**: State your preference with reasoning
5. **Wait for user decision** before coding

**Example**:

> "I discovered that Groq's Responses API doesn't support the built-in web search tool. I have three options:
>
> 1. **Remove web search** from planning (simplest, but loses key feature)
> 2. **Integrate Compound API** (enables web search, but adds complexity)
> 3. **Implement custom HTTP outcall** for search (full control, most work)
>
> I recommend option 2 (Compound API) since web search was a core requirement. Should I proceed with that approach?"

## Architectural Patterns

### Guard Rails vs Service Logic

**Guard rails (authentication, authorization, validation)** must be implemented at the **controller level (main.mo)**, not buried inside service functions.

## Testing Practices

### Prefer `expect` Over `assert`

In Motoko tests, **use `expect` syntax instead of `assert`**. The `expect` API provides better error messages with actual vs expected values.

Refer to `.mops/test@{version}/README.md` for complete `expect` documentation and examples.

## How to Verify Your Work

**Always start by checking for errors using the get_errors tool.** This catches compilation errors, type issues, and lint warnings. Once confirmed, use the language-specific checks below.

### For Motoko Code

Use dfx build with the `--check` flag to verify Motoko src code without creating canisters:

```bash
# Check Motoko files for compilation errors
dfx build open-org-backend --check
```

If it's tests written in Motoko you modified, run the mops test instead:

```bash
# Run Motoko tests
mops test
```

### For TypeScript Code

Use the TypeScript compiler to verify integration tests code:

```bash
# Type-check TypeScript without emitting
bun run tsc --noEmit
```

## Architecture

Please be aware of an [ARCHITECTURE.md](../ARCHITECTURE.md) file in the repository that provides detailed information about the system architecture, design decisions, and component interactions. Reviewing this document will help you understand the overall structure and design principles of the project.
