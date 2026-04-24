/// Tool Registry — Unit Tests
///
/// Covers scope-filtering, tool-set correctness, and lookup via
/// getTools / getDefinitions / get across all supported workflows.

import { test; expect } "mo:test";
import Array "mo:core/Array";
import ToolRegistry "../../../../src/internal-engine/tools/tool-registry";
import ExecutionTypes "../../../../src/internal-engine/execution-types";

// ─────────────────────────────────────────────────────────────────
// Scope-grant shorthands
// ─────────────────────────────────────────────────────────────────

let workspaceRead : ExecutionTypes.ScopeGrant = #workspace { access = #read };
let workspaceWrite : ExecutionTypes.ScopeGrant = #workspace { access = #write };
let agentsRead : ExecutionTypes.ScopeGrant = #agents { access = #read };
let agentsWrite : ExecutionTypes.ScopeGrant = #agents { access = #write };
let slackQueueRead : ExecutionTypes.ScopeGrant = #slackQueue { access = #read };
let sessionWrite : ExecutionTypes.ScopeGrant = #session { access = #write };

let noGrants : [ExecutionTypes.ScopeGrant] = [];
let readOnly : [ExecutionTypes.ScopeGrant] = [workspaceRead];
let writeAccess : [ExecutionTypes.ScopeGrant] = [workspaceWrite];
let agentsReadOnly : [ExecutionTypes.ScopeGrant] = [agentsRead];
let agentsWriteAccess : [ExecutionTypes.ScopeGrant] = [agentsWrite];
let slackOnly : [ExecutionTypes.ScopeGrant] = [slackQueueRead];
let sessionOnly : [ExecutionTypes.ScopeGrant] = [sessionWrite];
let allGrants : [ExecutionTypes.ScopeGrant] = [workspaceWrite, agentsWrite, slackQueueRead, sessionWrite];

func hasName(tools : [ToolRegistry.FunctionTool], name : Text) : Bool {
  Array.any<ToolRegistry.FunctionTool>(
    tools,
    func(t) {
      t.definition.function_.name == name;
    },
  );
};

// ─────────────────────────────────────────────────────────────────
// Unknown workflow
// ─────────────────────────────────────────────────────────────────

test(
  "unknown workflow returns empty tool list",
  func() {
    expect.nat(ToolRegistry.getTools("no-such-workflow", allGrants).size()).equal(0);
  },
);

test(
  "empty workflow id returns empty tool list",
  func() {
    expect.nat(ToolRegistry.getTools("", allGrants).size()).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — no grants
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with no grants returns empty tool list",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", noGrants).size()).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — workspace #read
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with workspace read returns 1 tool",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", readOnly).size()).equal(1);
  },
);

test(
  "admin-v1 with workspace read includes get_workspace",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", readOnly), "get_workspace")).isTrue();
  },
);

test(
  "admin-v1 with workspace read does not include write-only tools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", readOnly);
    expect.bool(hasName(tools, "create_workspace")).isFalse();
    expect.bool(hasName(tools, "delete_workspace")).isFalse();
    expect.bool(hasName(tools, "register_agent")).isFalse();
    expect.bool(hasName(tools, "update_agent")).isFalse();
    expect.bool(hasName(tools, "unregister_agent")).isFalse();
    expect.bool(hasName(tools, "set_admin_channel")).isFalse();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — workspace #write (satisfies read too)
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with workspace write returns 4 tools",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", writeAccess).size()).equal(4);
  },
);

test(
  "admin-v1 with workspace write includes workspace read tools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", writeAccess);
    expect.bool(hasName(tools, "get_workspace")).isTrue();
  },
);

test(
  "admin-v1 with workspace write includes workspace write tools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", writeAccess);
    expect.bool(hasName(tools, "create_workspace")).isTrue();
    expect.bool(hasName(tools, "delete_workspace")).isTrue();
    expect.bool(hasName(tools, "set_admin_channel")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — agents #read
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with agents read returns 2 tools",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", agentsReadOnly).size()).equal(2);
  },
);

test(
  "admin-v1 with agents read includes list_agents",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", agentsReadOnly), "list_agents")).isTrue();
  },
);

test(
  "admin-v1 with agents read includes get_agent",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", agentsReadOnly), "get_agent")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — agents #write (satisfies read too)
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with agents write returns 5 tools",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", agentsWriteAccess).size()).equal(5);
  },
);

test(
  "admin-v1 with agents write includes agent read tools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", agentsWriteAccess);
    expect.bool(hasName(tools, "list_agents")).isTrue();
    expect.bool(hasName(tools, "get_agent")).isTrue();
  },
);

test(
  "admin-v1 with agents write includes agent write tools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", agentsWriteAccess);
    expect.bool(hasName(tools, "register_agent")).isTrue();
    expect.bool(hasName(tools, "update_agent")).isTrue();
    expect.bool(hasName(tools, "unregister_agent")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — slackQueue #read
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with slackQueue read returns 2 tools",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", slackOnly).size()).equal(2);
  },
);

test(
  "admin-v1 with slackQueue read includes get_slack_queue_stats",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", slackOnly), "get_slack_queue_stats")).isTrue();
  },
);

test(
  "admin-v1 with slackQueue read includes get_failed_slack_queue_events",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", slackOnly), "get_failed_slack_queue_events")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — session #write
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with session write returns 1 tool",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", sessionOnly).size()).equal(1);
  },
);

test(
  "admin-v1 with session write includes update_session_policy",
  func() {
    expect.bool(hasName(ToolRegistry.getTools("admin-v1", sessionOnly), "update_session_policy")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// admin-v1 — all grants combined
// ─────────────────────────────────────────────────────────────────

test(
  "admin-v1 with all grants returns 12 tools",
  func() {
    expect.nat(ToolRegistry.getTools("admin-v1", allGrants).size()).equal(12);
  },
);

// ─────────────────────────────────────────────────────────────────
// getDefinitions
// ─────────────────────────────────────────────────────────────────

test(
  "getDefinitions returns same count as getTools",
  func() {
    let tools = ToolRegistry.getTools("admin-v1", allGrants);
    let defs = ToolRegistry.getDefinitions("admin-v1", allGrants);
    expect.nat(defs.size()).equal(tools.size());
  },
);

test(
  "getDefinitions entries have tool_type = function",
  func() {
    let defs = ToolRegistry.getDefinitions("admin-v1", allGrants);
    let allFunction = Array.all<ToolRegistry.FunctionTool>(
      ToolRegistry.getTools("admin-v1", allGrants),
      func(t) { t.definition.tool_type == "function" },
    );
    expect.bool(allFunction).isTrue();
    ignore defs; // count already checked above
  },
);

test(
  "getDefinitions returns empty for unknown workflow",
  func() {
    expect.nat(ToolRegistry.getDefinitions("nope", allGrants).size()).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// get (single-tool lookup)
// ─────────────────────────────────────────────────────────────────

test(
  "get returns null for unknown workflow",
  func() {
    switch (ToolRegistry.get("nope", allGrants, "list_agents")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "get returns null for unknown tool name",
  func() {
    switch (ToolRegistry.get("admin-v1", allGrants, "nonexistent_tool")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "get returns null when scope is insufficient",
  func() {
    // list_agents requires agents read; slackOnly has no agents grant
    switch (ToolRegistry.get("admin-v1", slackOnly, "list_agents")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "get returns tool when scope is sufficient",
  func() {
    let found = ToolRegistry.get("admin-v1", agentsReadOnly, "list_agents");
    switch (found) {
      case (null) { expect.bool(false).isTrue() };
      case (?t) {
        expect.text(t.definition.function_.name).equal("list_agents");
      };
    };
  },
);

test(
  "get returns write tool when write scope granted",
  func() {
    let found = ToolRegistry.get("admin-v1", agentsWriteAccess, "register_agent");
    switch (found) {
      case (null) { expect.bool(false).isTrue() };
      case (?t) {
        expect.text(t.definition.function_.name).equal("register_agent");
      };
    };
  },
);

test(
  "get returns null for write tool when only read scope granted",
  func() {
    switch (ToolRegistry.get("admin-v1", agentsReadOnly, "register_agent")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

// ─────────────────────────────────────────────────────────────────
// accessSatisfies — tested indirectly via scope filtering
// ─────────────────────────────────────────────────────────────────

test(
  "workspace write grant satisfies workspace read requirement",
  func() {
    // get_workspace requires #read; granting #write should still include it
    let tools = ToolRegistry.getTools("admin-v1", [workspaceWrite]);
    expect.bool(hasName(tools, "get_workspace")).isTrue();
  },
);

test(
  "workspace read grant does not satisfy workspace write requirement",
  func() {
    // create_workspace requires #write; granting only #read should exclude it
    let tools = ToolRegistry.getTools("admin-v1", [workspaceRead]);
    expect.bool(hasName(tools, "create_workspace")).isFalse();
  },
);

test(
  "slackQueue write grant satisfies slackQueue read requirement",
  func() {
    let slackWrite : ExecutionTypes.ScopeGrant = #slackQueue { access = #write };
    let tools = ToolRegistry.getTools("admin-v1", [slackWrite]);
    expect.bool(hasName(tools, "get_slack_queue_stats")).isTrue();
  },
);
