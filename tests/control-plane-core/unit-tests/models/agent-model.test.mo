import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import AgentModel "../../../../src/control-plane-core/models/agent-model";

// ============================================
// Helpers
// ============================================

func resultNatToText(r : Result.Result<Nat, Text>) : Text {
  switch (r) {
    case (#ok v) { "#ok(" # Nat.toText(v) # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultNatEqual(r1 : Result.Result<Nat, Text>, r2 : Result.Result<Nat, Text>) : Bool {
  r1 == r2;
};

func resultBoolToText(r : Result.Result<Bool, Text>) : Text {
  switch (r) {
    case (#ok b) { "#ok(" # debug_show (b) # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultBoolEqual(r1 : Result.Result<Bool, Text>, r2 : Result.Result<Bool, Text>) : Bool {
  r1 == r2;
};

/// Returns true when the option is Some (without comparing the value).
func isSomeRecord(x : ?AgentModel.AgentRecord) : Bool {
  switch (x) { case (null) false; case (_) true };
};

func isNoneRecord(x : ?AgentModel.AgentRecord) : Bool {
  switch (x) { case (null) true; case (_) false };
};

/// Convenience: register an agent with minimal config, returning the state.
func registerSimple(state : AgentModel.AgentRegistryState, name : Text, category : AgentModel.AgentCategory) : Result.Result<Nat, Text> {
  AgentModel.register(
    state,
    0,
    category,
    {
      name;
      model = "openai/gpt-oss-120b";
      allowedChannelIds = Set.singleton<Text>("C_TEST");
      workflowEngines = [#canister];
      secrets = { allowed = []; overrides = [] };
    },
  );
};

// ============================================
// Suite: emptyState / newToolState
// ============================================

suite(
  "AgentModel - emptyState and newToolState",
  func() {
    test(
      "emptyState() creates a registry state with no agents",
      func() {
        let state = AgentModel.emptyState();
        expect.nat(state.nextId).equal(0);
        expect.nat(AgentModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "newToolState() has zero usageCount and empty knowHow",
      func() {
        let ts = AgentModel.newToolState();
        expect.nat(ts.usageCount).equal(0);
        expect.text(ts.knowHow).equal("");
      },
    );
  },
);

// ============================================
// Suite: register
// ============================================

suite(
  "AgentModel - register",
  func() {

    test(
      "registers a valid agent and assigns incrementing ID",
      func() {
        let state = AgentModel.emptyState();
        let result = registerSimple(state, "my-agent", #_system(#admin));

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(0));
        expect.nat(state.nextId).equal(1);
        expect.nat(AgentModel.listAgents(state).size()).equal(1);
      },
    );

    test(
      "increments ID for each registered agent",
      func() {
        let state = AgentModel.emptyState();
        let r1 = registerSimple(state, "agent-one", #_system(#admin));
        let r2 = registerSimple(state, "agent-two", #_system(#onboarding));
        let r3 = registerSimple(state, "agent-three", #custom);

        expect.result<Nat, Text>(r1, resultNatToText, resultNatEqual).equal(#ok(0));
        expect.result<Nat, Text>(r2, resultNatToText, resultNatEqual).equal(#ok(1));
        expect.result<Nat, Text>(r3, resultNatToText, resultNatEqual).equal(#ok(2));
        expect.nat(state.nextId).equal(3);
      },
    );

    test(
      "normalises name to lowercase on registration",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "MyAgent", #custom);

        // Lookup with original casing should work
        expect.bool(isSomeRecord(AgentModel.lookupByName(state, "MyAgent"))).equal(true);
      },
    );

    test(
      "rejects empty name",
      func() {
        let state = AgentModel.emptyState();
        let result = registerSimple(state, "", #_system(#admin));

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name cannot be empty.")
        );
      },
    );

    test(
      "rejects name starting with a digit",
      func() {
        let state = AgentModel.emptyState();
        let result = registerSimple(state, "1agent", #_system(#admin));

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name must start with a lowercase letter.")
        );
      },
    );

    test(
      "rejects name with invalid characters",
      func() {
        let state = AgentModel.emptyState();
        let result = registerSimple(state, "my agent", #_system(#admin));

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name may only contain lowercase letters, digits, and hyphens.")
        );
      },
    );

    test(
      "rejects duplicate name (case-insensitive)",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "my-agent", #_system(#admin));

        let result = registerSimple(state, "MY-AGENT", #custom);
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("An agent named \"my-agent\" is already registered.")
        );
      },
    );

    test(
      "stores provided model and name in config",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #custom,
          {
            name = "info-bot";
            model = "openai/gpt-o3";
            allowedChannelIds = Set.singleton<Text>("C_TEST");
            workflowEngines = [#canister];
            secrets = { allowed = []; overrides = [] };
          },
        );

        switch (AgentModel.lookupByName(state, "info-bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?record) {
            expect.text(record.config.model).equal("openai/gpt-o3");
            expect.text(record.config.name).equal("info-bot");
          };
        };
      },
    );

    test(
      "accepts name with hyphens and digits",
      func() {
        let state = AgentModel.emptyState();
        let result = registerSimple(state, "agent-42", #custom);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
      },
    );

    test(
      "register accepts empty workflowEngines",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.register(
          state,
          1,
          #custom,
          {
            name = "no-engine-bot";
            model = "openai/gpt-o3";
            allowedChannelIds = Set.singleton<Text>("C_TEST");
            workflowEngines = [];
            secrets = { allowed = []; overrides = [] };
          },
        );
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
        switch (AgentModel.lookupByName(state, "no-engine-bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.bool(r.config.workflowEngines == []).equal(true);
          };
        };
      },
    );
  },
);

// ============================================
// Suite: lookupById / lookupByName
// ============================================

suite(
  "AgentModel - lookupById and lookupByName",
  func() {

    test(
      "lookupById returns null for non-existent agent",
      func() {
        let state = AgentModel.emptyState();
        expect.bool(isNoneRecord(AgentModel.lookupById(state, 999))).equal(true);
      },
    );

    test(
      "lookupByName returns null for non-existent agent",
      func() {
        let state = AgentModel.emptyState();
        expect.bool(isNoneRecord(AgentModel.lookupByName(state, "ghost"))).equal(true);
      },
    );

    test(
      "lookupById returns registered agent",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "planner", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        expect.bool(isSomeRecord(AgentModel.lookupById(state, id))).equal(true);
      },
    );

    test(
      "lookupByName is case-insensitive",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "planner", #_system(#admin));

        expect.bool(isSomeRecord(AgentModel.lookupByName(state, "PLANNER"))).equal(true);
        expect.bool(isSomeRecord(AgentModel.lookupByName(state, "Planner"))).equal(true);
        expect.bool(isSomeRecord(AgentModel.lookupByName(state, "planner"))).equal(true);
      },
    );
  },
);

// ============================================
// Suite: updateById
// ============================================

suite(
  "AgentModel - updateById",
  func() {

    test(
      "updates model",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentModel.updateById(
          state,
          id,
          {
            name = null;
            model = ?"openai/gpt-4o";
            workflowEngines = null;
            secretsAllowed = null;
            secretOverrides = null;
            allowedChannelIds = null;
          },
        );
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.text(r.config.model).equal("openai/gpt-4o");
          };
        };
      },
    );

    test(
      "updates workflowEngines",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        ignore AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = ?[#canister, #github]; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.bool(r.config.workflowEngines == [#canister, #github]).equal(true);
          };
        };
      },
    );

    test(
      "updates workflowEngines to empty array",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        ignore AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = ?[]; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.bool(r.config.workflowEngines == []).equal(true);
          };
        };
      },
    );

    test(
      "updates name and maintains index consistency",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "old-bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Update name to new-bot
        let result = AgentModel.updateById(state, id, { name = ?"new-bot"; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        // Old name should no longer resolve
        expect.bool(isNoneRecord(AgentModel.lookupByName(state, "old-bot"))).equal(true);

        // New name should resolve to the same agent
        switch (AgentModel.lookupByName(state, "new-bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.id).equal(id) };
        };

        // Lookup by ID should show updated name
        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.config.name).equal("new-bot") };
        };
      },
    );

    test(
      "rejects duplicate name when updating",
      func() {
        let state = AgentModel.emptyState();
        let id1 = switch (registerSimple(state, "bot-one", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };
        ignore registerSimple(state, "bot-two", #custom);

        // Try to rename bot-one to bot-two (which already exists)
        let result = AgentModel.updateById(state, id1, { name = ?"bot-two"; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();

        // bot-one should still have its original name
        switch (AgentModel.lookupById(state, id1)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.config.name).equal("bot-one") };
        };
      },
    );

    test(
      "allows same agent to keep its name (no-op)",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Update with the same name (case variation)
        let result = AgentModel.updateById(state, id, { name = ?"BOT"; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        // Lookup should still work
        expect.bool(isSomeRecord(AgentModel.lookupByName(state, "bot"))).equal(true);
      },
    );

    test(
      "rejects invalid name format when updating",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "valid-bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Try to update with invalid name (starting with digit)
        let result = AgentModel.updateById(state, id, { name = ?"1invalid"; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();

        // Original name should still be intact
        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.config.name).equal("valid-bot") };
        };
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.updateById(state, 999, { name = null; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: updateToolState
// ============================================

suite(
  "AgentModel - updateToolState",
  func() {

    test(
      "adds a new tool state entry",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let ts : AgentModel.ToolState = {
          usageCount = 3;
          knowHow = "use POST endpoint";
        };
        let result = AgentModel.updateToolState(state, id, "web_search", ts);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            switch (Map.get(r.state.toolsState, Text.compare, "web_search")) {
              case (null) { expect.bool(false).equal(true) };
              case (?found) {
                expect.nat(found.usageCount).equal(3);
                expect.text(found.knowHow).equal("use POST endpoint");
              };
            };
          };
        };
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.updateToolState(
          state,
          999,
          "tool",
          AgentModel.newToolState(),
        );
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: secretsAllowed
// ============================================

suite(
  "AgentModel - secretsAllowed",
  func() {

    test(
      "registers with empty secretsAllowed by default",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "bot", #_system(#admin));

        switch (AgentModel.lookupByName(state, "bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.config.secrets.allowed.size()).equal(0);
          };
        };
      },
    );

    test(
      "registers with explicit secretsAllowed entries",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "secure-bot";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = {
              allowed = [(1, #openRouterApiKey), (2, #custom("tool-key"))];
              overrides = [];
            };
          },
        );

        switch (AgentModel.lookupByName(state, "secure-bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.config.secrets.allowed.size()).equal(2);
          };
        };
      },
    );

    test(
      "updateById replaces secretsAllowed",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = null; secretsAllowed = ?[(0, #openRouterApiKey)]; secretOverrides = null; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.config.secrets.allowed.size()).equal(1);
          };
        };
      },
    );

    test(
      "updateById clears secretsAllowed when passed empty array",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "bot";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = { allowed = [(1, #openRouterApiKey)]; overrides = [] };
          },
        );
        let id = 0;

        ignore AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = null; secretsAllowed = ?[]; secretOverrides = null; allowedChannelIds = null });

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.config.secrets.allowed.size()).equal(0);
          };
        };
      },
    );
  },
);

// ============================================
// Suite: secretOverrides
// ============================================

suite(
  "AgentModel - secretOverrides",
  func() {

    test(
      "registers with empty secretOverrides by default",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "bot", #_system(#admin));
        switch (AgentModel.lookupByName(state, "bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.config.secrets.overrides.size()).equal(0) };
        };
      },
    );

    test(
      "registers with explicit secretOverrides entries",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #custom,
          {
            name = "override-bot";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.singleton<Text>("C_TEST");
            workflowEngines = [#canister];
            secrets = {
              allowed = [];
              overrides = [(#openRouterApiKey, "my-custom-key"), (#custom("alt-key"), "another-key")];
            };
          },
        );
        switch (AgentModel.lookupByName(state, "override-bot")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.config.secrets.overrides.size()).equal(2) };
        };
      },
    );

    test(
      "updateById replaces secretOverrides",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };
        let result = AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = ?[(#openRouterApiKey, "my-key")]; allowedChannelIds = null });
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));
        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.config.secrets.overrides.size()).equal(1) };
        };
      },
    );

    test(
      "updateById clears secretOverrides when passed empty array",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "bot";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = {
              allowed = [];
              overrides = [(#openRouterApiKey, "my-key")];
            };
          },
        );
        let id = 0;
        ignore AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = ?[]; allowedChannelIds = null });
        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.config.secrets.overrides.size()).equal(0) };
        };
      },
    );

    test(
      "updateById preserves existing secretOverrides when null is passed",
      func() {
        let state = AgentModel.emptyState();
        ignore AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "bot";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = {
              allowed = [];
              overrides = [(#openRouterApiKey, "keep-this")];
            };
          },
        );
        let id = 0;
        ignore AgentModel.updateById(state, id, { name = null; model = null; workflowEngines = null; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null });
        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.config.secrets.overrides.size()).equal(1) };
        };
      },
    );
  },
);

// ============================================
// Suite: unregisterById
// ============================================

suite(
  "AgentModel - unregisterById",
  func() {

    test(
      "removes a registered agent",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "bot", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentModel.unregisterById(state, id);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));
        expect.bool(isNoneRecord(AgentModel.lookupById(state, id))).equal(true);
        expect.bool(isNoneRecord(AgentModel.lookupByName(state, "bot"))).equal(true);
        expect.nat(AgentModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.unregisterById(state, 999);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: listAgents
// ============================================

suite(
  "AgentModel - listAgents",
  func() {

    test(
      "returns empty array for empty state",
      func() {
        let state = AgentModel.emptyState();
        expect.nat(AgentModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "returns all registered agents",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "alpha", #_system(#admin));
        ignore registerSimple(state, "beta", #custom);
        ignore registerSimple(state, "gamma", #_system(#onboarding));

        expect.nat(AgentModel.listAgents(state).size()).equal(3);
      },
    );

    test(
      "does not include unregistered agents",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "alpha", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };
        ignore registerSimple(state, "beta", #custom);
        ignore AgentModel.unregisterById(state, id);

        expect.nat(AgentModel.listAgents(state).size()).equal(1);
      },
    );
  },
);

// ============================================
// Suite: allowedChannelIds — #_system(#admin) category coercion
// ============================================

suite(
  "AgentModel - allowedChannelIds #_system(#admin) coercion",
  func() {

    test(
      "register: #_system(#admin) agent always stores empty allowedChannelIds regardless of input",
      func() {
        let state = AgentModel.emptyState();
        // Pass a non-empty set — should be coerced to empty for #_system(#admin).
        ignore AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "org-admin";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.singleton<Text>("C_SHOULD_BE_IGNORED");
            workflowEngines = [#canister];
            secrets = { allowed = []; overrides = [] };
          },
        );
        switch (AgentModel.lookupByName(state, "org-admin")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(Set.size(r.config.allowedChannelIds)).equal(0);
          };
        };
      },
    );

    test(
      "register: #_system(#admin) agent succeeds with empty allowedChannelIds (no non-empty invariant error)",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.register(
          state,
          0,
          #_system(#admin),
          {
            name = "org-admin";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = { allowed = []; overrides = [] };
          },
        );
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
      },
    );

    test(
      "register: non-admin agent still rejects empty allowedChannelIds",
      func() {
        let state = AgentModel.emptyState();
        let result = AgentModel.register(
          state,
          0,
          #custom,
          {
            name = "planner";
            model = "openai/gpt-oss-120b";
            allowedChannelIds = Set.empty<Text>();
            workflowEngines = [#canister];
            secrets = { allowed = []; overrides = [] };
          },
        );
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("allowedChannelIds must contain at least one channel ID.")
        );
      },
    );

    test(
      "updateById: passing non-empty allowedChannelIds for #_system(#admin) is silently coerced to empty",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "org-admin", #_system(#admin))) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        ignore AgentModel.updateById(
          state,
          id,
          {
            name = null;
            model = null;
            workflowEngines = null;
            secretsAllowed = null;
            secretOverrides = null;
            allowedChannelIds = ?Set.singleton<Text>("C_NEW_CHANNEL");
          },
        );

        switch (AgentModel.lookupById(state, id)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(Set.size(r.config.allowedChannelIds)).equal(0);
          };
        };
      },
    );

    test(
      "updateById: passing empty allowedChannelIds for non-admin returns error",
      func() {
        let state = AgentModel.emptyState();
        let id = switch (registerSimple(state, "planner", #custom)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentModel.updateById(
          state,
          id,
          {
            name = null;
            model = null;
            workflowEngines = null;
            secretsAllowed = null;
            secretOverrides = null;
            allowedChannelIds = ?Set.empty<Text>();
          },
        );
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("allowedChannelIds must contain at least one channel ID; the allowlist cannot be emptied.")
        );
      },
    );

    test(
      "defaultState: built-in workspace-admin agent has empty allowedChannelIds",
      func() {
        let state = AgentModel.defaultState();
        switch (AgentModel.lookupByName(state, "workspace-admin")) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(Set.size(r.config.allowedChannelIds)).equal(0);
          };
        };
      },
    );
  },
);
