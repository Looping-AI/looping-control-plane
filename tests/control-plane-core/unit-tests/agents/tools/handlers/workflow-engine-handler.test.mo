import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import AgentModel "../../../../../../src/control-plane-core/models/agent-model";
import AgentHelpers "../../../../../../src/control-plane-core/agents/helpers";

// ─── Helper ──────────────────────────────────────────────────────────────────

/// Minimal AgentRecord for scope-grant tests.  ownedBy=0 → org workspace.
func makeAgent(category : AgentModel.AgentCategory, ownedBy : Nat, id : Nat) : AgentModel.AgentRecord {
  {
    id;
    ownedBy;
    category;
    config = {
      name = "test-agent";
      model = "openai/gpt-oss-120b";
      workflowEngines = [#canister];
      allowedChannelIds = Set.empty<Text>();
      secrets = { allowed = []; overrides = [] };
    };
    state = {
      toolsState = Map.empty<Text, AgentModel.ToolState>();
    };
  };
};

// ─── Tests ───────────────────────────────────────────────────────────────────

suite(
  "AgentHelpers - buildScopeGrants",
  func() {

    test(
      "org-admin (ownedBy=0, #_system(#admin)) receives 4 write grants",
      func() {
        let agent = makeAgent(#_system(#admin), 0, 0);
        let grants = AgentHelpers.buildScopeGrants(agent);
        expect.nat(grants.size()).equal(4);
        // Verify each expected grant variant is present
        var hasWorkspaceWrite = false;
        var hasAgentsWrite = false;
        var hasSlackQueueWrite = false;
        var hasSessionWrite = false;
        for (g in grants.vals()) {
          switch (g) {
            case (#workspace({ access = #write })) { hasWorkspaceWrite := true };
            case (#agents({ access = #write })) { hasAgentsWrite := true };
            case (#slackQueue({ access = #write })) {
              hasSlackQueueWrite := true;
            };
            case (#session({ access = #write })) { hasSessionWrite := true };
            case (_) {};
          };
        };
        expect.bool(hasWorkspaceWrite).isTrue();
        expect.bool(hasAgentsWrite).isTrue();
        expect.bool(hasSlackQueueWrite).isTrue();
        expect.bool(hasSessionWrite).isTrue();
      },
    );

    test(
      "workspace-admin (ownedBy=1, #_system(#admin)) receives 3 grants (no slackQueue write)",
      func() {
        let agent = makeAgent(#_system(#admin), 1, 1);
        let grants = AgentHelpers.buildScopeGrants(agent);
        expect.nat(grants.size()).equal(3);
        var hasWorkspaceRead = false;
        var hasAgentsWrite = false;
        var hasSessionWrite = false;
        var hasSlackQueueWrite = false;
        for (g in grants.vals()) {
          switch (g) {
            case (#workspace({ access = #read })) { hasWorkspaceRead := true };
            case (#agents({ access = #write })) { hasAgentsWrite := true };
            case (#session({ access = #write })) { hasSessionWrite := true };
            case (#slackQueue({ access = #write })) {
              hasSlackQueueWrite := true;
            };
            case (_) {};
          };
        };
        expect.bool(hasWorkspaceRead).isTrue();
        expect.bool(hasAgentsWrite).isTrue();
        expect.bool(hasSessionWrite).isTrue();
        expect.bool(hasSlackQueueWrite).isFalse();
      },
    );

    test(
      "#_system(#onboarding) receives 1 per-agent read grant",
      func() {
        let agent = makeAgent(#_system(#onboarding), 0, 3);
        let grants = AgentHelpers.buildScopeGrants(agent);
        expect.nat(grants.size()).equal(1);
        let isAgentRead = switch (grants[0]) {
          case (#agent({ id = 3; access = #read })) { true };
          case (_) { false };
        };
        expect.bool(isAgentRead).isTrue();
      },
    );

    test(
      "#custom receives 1 per-agent read grant bound to the agent id",
      func() {
        let agent = makeAgent(#custom, 2, 7);
        let grants = AgentHelpers.buildScopeGrants(agent);
        expect.nat(grants.size()).equal(1);
        let isAgentRead = switch (grants[0]) {
          case (#agent({ id = 7; access = #read })) { true };
          case (_) { false };
        };
        expect.bool(isAgentRead).isTrue();
      },
    );
  },
);
