# Architecture

## Purpose

This repo is meant to be forked, adapted and expanded to whatever personal or business need you may have.
The goal is to have Autonomous AI Agents within yours or an organization control, that we can call and feel like a working colleague or a personal coach.
There is a strong focus on goals, that are set within workspaces by Admins.
Humans and AI Agents should seamlessly interact within familiar platforms, like Slack, email or a community chat app.
The Agent should be autonomous, to experiment and learn, to see through different existent or self-created tooling if a goal metric increments in the desired direction.
It should be easy to track costs and always have associated an attribution model that allows to see which parts are more impactful, better performing, while others need to be revisited.
In the end, the main goal is a sovereign, autonomous and seamless way for human-ai teams to co-exist.

## Reading Guide

- This file is general purpose until X section, and reading it is advised to all.
- From section X onwards, the content is more specialized, with deep dives that are only relevant if you are having any trouble in that area or are considering altering it.

## Key Goals

- {Populate based on Purpose}

## Non-Goals

- {Give suggestions}

## System Overview

Canisters:

- Root Canister (Controlled by Main)
- Main Canister (Controlled by Root)
- Frontend Canister (Org & Workspace Dashboard)

Main Canister interacts with:

- LLMs (Groq, OpenAI, ...)
- UI Integrations (Slack Bot, OC Bot, TG Bot, Email, ...)
- Tools (LLM internal (like web search), external or custom (APIs, MCPs, Anchor Browser, controlled canisters (by wasm), etc.))
- Callbacks are ingested for stats, events, triggers, ...

## Architecture Principles

- Mixture of Agents vs Single Agents (due to smaller input tokens, A/B testing, choice of diff LLM Models, less tooling, less risk of info leak, etc.)
- Task Types (and real time assignment based on past performance) over Roles (and pre-assigned workloads)
- Quality over Quantity (or cost)
- Sustainably Human vs AI Only (prefer human every time quality is better, despite much higher cost).
- Transparency vs Obedience (same as in Humans. We want to control context and goals, then see it perform. Not micromanage, although there is weight in an Admin talking and some natural weight when a Member is talking. But we shouldn't make it obedient for a few reasons: prompt hacking, disruption with other tasks that human isn't aware, difficulty to guarantee that a prompt is coming from a Human vs another Agent, etc.)
- Humans / Admins only care about Providers (API Keys), allowing tools and giving feedback, and in deleting agents (effectively firing a malfunctioning agent, ensuring it can't be picked up again for any task). They should be abstracted about deciding the best LLM model or the best tool for a task.

## Core Concepts

- Organization (Main Canister)
- Organization Workspace (Nr 0 and can't be deleted, deleting it means deleting dependencies, then root to delete main, then root to create as many fake memory as it, then allow public to access method to drain itself out of cycles,and wait for the freezing + empty cycles to be reached.)
- Org Workspace Fixed Policy (1 Owner only -> needs to be transferred + dead man switch after 1 year of inactivity (Any Admin can Claim Ownership). Any nr of Admins)
- Workspaces (Owners, Admins and Members (write permission), public can read all data as members if Admin configures)
- Workspaces have API Keys, Agents, Goals, Budgets and Tasks.
- Organization Workspace controls the workspaces below and any interactions between them, through Policies. Any workspace can create further workspaces below, having that parent workspace the right to set policy on the workspace below.
- Policies make it easier to avoid managing workspaces one by one neither micromanage it.

## External Interfaces

- Canister Frontend (Org and Workspace Dashboard)
- Slack
- Email
- Chat App

## Core Flows

Org Config by Admin:

- workspaceCredentials (workspaceId, { credential: { ProviderEnum, value } });
- adminTalk (workspaceId, message) - only way to change admin state (also doesn't change workspace state) respecting a given policy:
  - New Workspace set up (or delete)
  - Set goals, budgets and policies on child-workspaces
  - Add/Remove Admin on child-workspaces (on 0, only owner)
  - Request approvals (for Agent Creation (with respective Policy and Tool Allowlist), over budget usage, etc.)
  - Internal Goals set up
  - Set up recurring tasks and frequency of them.
    ...
- workspaceTalk(workspaceId, message) - Changes Workspace State, respecting a given policy, aiming at a goal and constrained by budget.
  - Plans and sets up tasks;
  - pulls / calculates metrics;
  - analyze and set costs;
    ...
- eventHandle(...) - Handles external incoming events like:
  - metrics events;
  - new information (from group messages);
    ...
- executeTasks(?workspaceId) - pending tasks of a specific workspaceId or do all sequentially, a pending task will be assigned to the best agent. There are some "workspace" / "recurring" tasks, like goal monitoring, agent creation/management/improvement, etc.

## State Model

Canister (Organization Level):

- Org Owner and Admins
- Consts (Very few)
- workspaceCredentials Mapping
- adminStates Mapping and workspaceStates Mapping:
  - Wrapped inside AdminStateClass (Admin State of a specific Workspace)
  - Wrapped inside WorkspaceStateClass (Workspace State of a specific Workspace)
- Timers State

Admin State of a Workspace:

- Admins, Members and public read setting.
- Admin Conversation History;
- Admin Events History;
  ...

Workspace State of a Workspace:

- Workspace Conversation History;
- Workspace Events History;
- Tasks State and History;
- Goals State and History;
- Attributions State and History;
- Budget State and History;
- Agents State;
- Tools State;
- Knowledge State;
  ...

## Identity, Roles, and Authorization

- {Give suggestions}

## Task Execution Model

- {Give suggestions}

## Concurrency and Await Safety

- {Give suggestions}

## Timers and Scheduling

- {Give suggestions}

## Tooling and Integrations

- {Give suggestions}

## LLM Providers and Wrappers

- {Give suggestions}

## Secrets, API Keys, and Encryption

- {Give suggestions}

## Observability and Impact Tracking

- {Give suggestions}

## Cost Controls and Budgeting

- {Give suggestions}

## Error Handling and Retries

- {Give suggestions}

## Data Retention and Privacy

- {Give suggestions}

## Upgrade and Persistence Strategy

- {Give suggestions}

## Testing Strategy

- {Give suggestions}

## Local Development and Reproducibility

- {Give suggestions}

## Deep Dives

- {Give suggestions}

### Controller Layer (Entry Points)

- {Give suggestions}

### Services Layer

- {Give suggestions}

### Wrappers Layer (HTTP Outcalls)

- {Give suggestions}

### Conversation Storage Model

- {Give suggestions}

### API Key Storage and Key Derivation

- {Give suggestions}

### Timer Lifecycle and Post-Upgrade Rehydration

- {Give suggestions}

### Task Queue and Idempotency

- {Give suggestions}

### Cassette-Based Testing System

- {Give suggestions}

## Glossary

- {Give suggestions}

## Open Questions

- {Give suggestions}

## Future Work

- {Give suggestions}
