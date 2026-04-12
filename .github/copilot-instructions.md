# GitHub Copilot Instructions

All coding conventions, architectural patterns, and workflow requirements for this
repository are documented in [AGENTS.md](../AGENTS.md). Read it before making any
changes.

## Pre-commit requirement

**Always run `bun run format` before committing.** The CI `test` workflow enforces
Prettier formatting via `bun run format:check` and will fail if files are not
formatted.

## Recording cassettes

You can record cassettes yourself — all required environment variables and firewall
domain permissions are configured and should work without any manual intervention.

```bash
RECORD_CASSETTES=true bun test <path-to-spec-file>
```

If recording fails due to a missing environment variable or a domain that is not on
the firewall allowlist, report it rather than working around it.
