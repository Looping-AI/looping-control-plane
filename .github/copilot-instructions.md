# GitHub Copilot Instructions

All coding conventions, architectural patterns, and workflow requirements for this
repository are documented in [AGENTS.md](../AGENTS.md). Read it before making any
changes.

## Pre-commit requirement

**Always run `bun run format` before committing.** The CI `test` workflow enforces
Prettier formatting via `bun run format:check` and will fail if files are not
formatted.
