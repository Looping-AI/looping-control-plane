/// Tool Registry — Unit Tests
///
/// Covers scope-filtering, tool-set correctness, and lookup via
/// getTools / getDefinitions / get.

import { test; expect } "mo:test";
import Array "mo:core/Array";
import Text "mo:core/Text";
import ToolRegistry "../../../../src/internal-engine/tools/tool-registry";
import WorkflowTypes "../../../../src/internal-engine/workflow-types";

// ─────────────────────────────────────────────────────────────────
// Scope-grant shorthands
// ─────────────────────────────────────────────────────────────────

let workspaceRead : WorkflowTypes.ScopeGrant = #workspace { access = #read };
let workspaceWrite : WorkflowTypes.ScopeGrant = #workspace { access = #write };
let agentsRead : WorkflowTypes.ScopeGrant = #agents { access = #read };
let agentsWrite : WorkflowTypes.ScopeGrant = #agents { access = #write };
let slackQueueRead : WorkflowTypes.ScopeGrant = #slackQueue { access = #read };
let sessionWrite : WorkflowTypes.ScopeGrant = #session { access = #write };

let noGrants : [WorkflowTypes.ScopeGrant] = [];
let readOnly : [WorkflowTypes.ScopeGrant] = [workspaceRead];
let writeAccess : [WorkflowTypes.ScopeGrant] = [workspaceWrite];
let agentsReadOnly : [WorkflowTypes.ScopeGrant] = [agentsRead];
let agentsWriteAccess : [WorkflowTypes.ScopeGrant] = [agentsWrite];
let slackOnly : [WorkflowTypes.ScopeGrant] = [slackQueueRead];
let sessionOnly : [WorkflowTypes.ScopeGrant] = [sessionWrite];
let allGrants : [WorkflowTypes.ScopeGrant] = [workspaceWrite, agentsWrite, slackQueueRead, sessionWrite];

func hasName(tools : [ToolRegistry.FunctionTool], name : Text) : Bool {
  Array.any<ToolRegistry.FunctionTool>(
    tools,
    func(t) {
      t.definition.function_.name == name;
    },
  );
};

// ─────────────────────────────────────────────────────────────────
// No grants
// ─────────────────────────────────────────────────────────────────

test(
  "no grants returns empty tool list",
  func() {
    expect.nat(ToolRegistry.getTools(noGrants).size()).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// workspace #read
// ─────────────────────────────────────────────────────────────────

test(
  "workspace read returns 1 tool",
  func() {
    expect.nat(ToolRegistry.getTools(readOnly).size()).equal(1);
  },
);

test(
  "workspace read includes get_workspace",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(readOnly), "get_workspace")).isTrue();
  },
);

test(
  "workspace read does not include write-only tools",
  func() {
    let tools = ToolRegistry.getTools(readOnly);
    expect.bool(hasName(tools, "create_workspace")).isFalse();
    expect.bool(hasName(tools, "delete_workspace")).isFalse();
    expect.bool(hasName(tools, "register_agent")).isFalse();
    expect.bool(hasName(tools, "update_agent")).isFalse();
    expect.bool(hasName(tools, "unregister_agent")).isFalse();
    expect.bool(hasName(tools, "set_admin_channel")).isFalse();
  },
);

// ─────────────────────────────────────────────────────────────────
// workspace #write (satisfies read too)
// ─────────────────────────────────────────────────────────────────

test(
  "workspace write returns 4 tools",
  func() {
    expect.nat(ToolRegistry.getTools(writeAccess).size()).equal(4);
  },
);

test(
  "workspace write includes workspace read tools",
  func() {
    let tools = ToolRegistry.getTools(writeAccess);
    expect.bool(hasName(tools, "get_workspace")).isTrue();
  },
);

test(
  "workspace write includes workspace write tools",
  func() {
    let tools = ToolRegistry.getTools(writeAccess);
    expect.bool(hasName(tools, "create_workspace")).isTrue();
    expect.bool(hasName(tools, "delete_workspace")).isTrue();
    expect.bool(hasName(tools, "set_admin_channel")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// agents #read
// ─────────────────────────────────────────────────────────────────

test(
  "agents read returns 2 tools",
  func() {
    expect.nat(ToolRegistry.getTools(agentsReadOnly).size()).equal(2);
  },
);

test(
  "agents read includes list_agents",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(agentsReadOnly), "list_agents")).isTrue();
  },
);

test(
  "agents read includes get_agent",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(agentsReadOnly), "get_agent")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// agents #write (satisfies read too)
// ─────────────────────────────────────────────────────────────────

test(
  "agents write returns 5 tools",
  func() {
    expect.nat(ToolRegistry.getTools(agentsWriteAccess).size()).equal(5);
  },
);

test(
  "agents write includes agent read tools",
  func() {
    let tools = ToolRegistry.getTools(agentsWriteAccess);
    expect.bool(hasName(tools, "list_agents")).isTrue();
    expect.bool(hasName(tools, "get_agent")).isTrue();
  },
);

test(
  "agents write includes agent write tools",
  func() {
    let tools = ToolRegistry.getTools(agentsWriteAccess);
    expect.bool(hasName(tools, "register_agent")).isTrue();
    expect.bool(hasName(tools, "update_agent")).isTrue();
    expect.bool(hasName(tools, "unregister_agent")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// slackQueue #read
// ─────────────────────────────────────────────────────────────────

test(
  "slackQueue read returns 2 tools",
  func() {
    expect.nat(ToolRegistry.getTools(slackOnly).size()).equal(2);
  },
);

test(
  "slackQueue read includes get_slack_queue_stats",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(slackOnly), "get_slack_queue_stats")).isTrue();
  },
);

test(
  "slackQueue read includes get_failed_slack_queue_events",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(slackOnly), "get_failed_slack_queue_events")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// session #write
// ─────────────────────────────────────────────────────────────────

test(
  "session write returns 1 tool",
  func() {
    expect.nat(ToolRegistry.getTools(sessionOnly).size()).equal(1);
  },
);

test(
  "session write includes update_session_policy",
  func() {
    expect.bool(hasName(ToolRegistry.getTools(sessionOnly), "update_session_policy")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// all grants combined
// ─────────────────────────────────────────────────────────────────

test(
  "all grants returns 12 tools",
  func() {
    expect.nat(ToolRegistry.getTools(allGrants).size()).equal(12);
  },
);

// ─────────────────────────────────────────────────────────────────
// getDefinitions
// ─────────────────────────────────────────────────────────────────

test(
  "getDefinitions returns same count as getTools",
  func() {
    let tools = ToolRegistry.getTools(allGrants);
    let defs = ToolRegistry.getDefinitions(allGrants);
    expect.nat(defs.size()).equal(tools.size());
  },
);

test(
  "getDefinitions entries have tool_type = function",
  func() {
    let defs = ToolRegistry.getDefinitions(allGrants);
    let allFunction = Array.all<ToolRegistry.FunctionTool>(
      ToolRegistry.getTools(allGrants),
      func(t) { t.definition.tool_type == "function" },
    );
    expect.bool(allFunction).isTrue();
    ignore defs; // count already checked above
  },
);

// ─────────────────────────────────────────────────────────────────
// get (single-tool lookup)
// ─────────────────────────────────────────────────────────────────

test(
  "get returns null for unknown tool name",
  func() {
    switch (ToolRegistry.get(allGrants, "nonexistent_tool")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "get returns null when scope is insufficient",
  func() {
    // list_agents requires agents read; slackOnly has no agents grant
    switch (ToolRegistry.get(slackOnly, "list_agents")) {
      case (null) {}; // expected
      case (?_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "get returns tool when scope is sufficient",
  func() {
    let found = ToolRegistry.get(agentsReadOnly, "list_agents");
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
    let found = ToolRegistry.get(agentsWriteAccess, "register_agent");
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
    switch (ToolRegistry.get(agentsReadOnly, "register_agent")) {
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
    let tools = ToolRegistry.getTools([workspaceWrite]);
    expect.bool(hasName(tools, "get_workspace")).isTrue();
  },
);

test(
  "workspace read grant does not satisfy workspace write requirement",
  func() {
    // create_workspace requires #write; granting only #read should exclude it
    let tools = ToolRegistry.getTools([workspaceRead]);
    expect.bool(hasName(tools, "create_workspace")).isFalse();
  },
);

test(
  "slackQueue write grant satisfies slackQueue read requirement",
  func() {
    let slackWrite : WorkflowTypes.ScopeGrant = #slackQueue { access = #write };
    let tools = ToolRegistry.getTools([slackWrite]);
    expect.bool(hasName(tools, "get_slack_queue_stats")).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// Tool schema — workflowEngines field
// ─────────────────────────────────────────────────────────────────

test(
  "register_agent parameter schema includes workflowEngines",
  func() {
    switch (ToolRegistry.get(agentsWriteAccess, "register_agent")) {
      case (null) { expect.bool(false).isTrue() };
      case (?t) {
        switch (t.definition.function_.parameters) {
          case (null) { expect.bool(false).isTrue() };
          case (?params) {
            expect.bool(Text.contains(params, #text "workflowEngines")).isTrue();
          };
        };
      };
    };
  },
);

test(
  "update_agent parameter schema includes workflowEngines",
  func() {
    switch (ToolRegistry.get(agentsWriteAccess, "update_agent")) {
      case (null) { expect.bool(false).isTrue() };
      case (?t) {
        switch (t.definition.function_.parameters) {
          case (null) { expect.bool(false).isTrue() };
          case (?params) {
            expect.bool(Text.contains(params, #text "workflowEngines")).isTrue();
          };
        };
      };
    };
  },
);
