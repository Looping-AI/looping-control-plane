import { test; suite; expect } "mo:test";
// AgentRouter only exposes `route`, which is async and requires full canister
// context (agents, secrets, LLM outcalls). Meaningful tests live in the
// TypeScript integration layer (message-handler.spec.ts).
// This file validates that the module compiles and imports cleanly.
import _AgentRouter "../../../../src/control-plane-core/events/agent-router";

suite(
  "AgentRouter - module import",
  func() {
    test(
      "module compiles and imports successfully",
      func() {
        // If this test runs at all, the module compiled.
        expect.bool(true).isTrue();
      },
    );
  },
);
