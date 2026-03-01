import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import AgentRegistryModel "../../../../src/open-org-backend/models/agent-registry-model";

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
func isSomeRecord(x : ?AgentRegistryModel.AgentRecord) : Bool {
  switch (x) { case (null) false; case (_) true };
};

func isNoneRecord(x : ?AgentRegistryModel.AgentRecord) : Bool {
  switch (x) { case (null) true; case (_) false };
};

/// Convenience: register an agent with minimal config, returning the state.
func registerSimple(state : AgentRegistryModel.AgentRegistryState, name : Text, category : AgentRegistryModel.AgentCategory) : Result.Result<Nat, Text> {
  AgentRegistryModel.register(
    name,
    category,
    #groq(#gpt_oss_120b),
    [],
    [],
    Map.empty<Text, AgentRegistryModel.ToolState>(),
    [],
    state,
  );
};

// ============================================
// Suite: emptyState / newToolState
// ============================================

suite(
  "AgentRegistryModel - emptyState and newToolState",
  func() {
    test(
      "emptyState() creates a registry state with no agents",
      func() {
        let state = AgentRegistryModel.emptyState();
        expect.nat(state.nextId).equal(0);
        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "newToolState() has zero usageCount and empty knowHow",
      func() {
        let ts = AgentRegistryModel.newToolState();
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
  "AgentRegistryModel - register",
  func() {

    test(
      "registers a valid agent and assigns incrementing ID",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = registerSimple(state, "my-agent", #admin);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(0));
        expect.nat(state.nextId).equal(1);
        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(1);
      },
    );

    test(
      "increments ID for each registered agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        let r1 = registerSimple(state, "agent-one", #admin);
        let r2 = registerSimple(state, "agent-two", #research);
        let r3 = registerSimple(state, "agent-three", #communication);

        expect.result<Nat, Text>(r1, resultNatToText, resultNatEqual).equal(#ok(0));
        expect.result<Nat, Text>(r2, resultNatToText, resultNatEqual).equal(#ok(1));
        expect.result<Nat, Text>(r3, resultNatToText, resultNatEqual).equal(#ok(2));
        expect.nat(state.nextId).equal(3);
      },
    );

    test(
      "normalises name to lowercase on registration",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore registerSimple(state, "MyAgent", #research);

        // Lookup with original casing should work
        expect.bool(isSomeRecord(AgentRegistryModel.lookupByName("MyAgent", state))).equal(true);
      },
    );

    test(
      "rejects empty name",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = registerSimple(state, "", #admin);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name cannot be empty.")
        );
      },
    );

    test(
      "rejects name starting with a digit",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = registerSimple(state, "1agent", #admin);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name must start with a lowercase letter.")
        );
      },
    );

    test(
      "rejects name with invalid characters",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = registerSimple(state, "my agent", #admin);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name may only contain lowercase letters, digits, and hyphens.")
        );
      },
    );

    test(
      "rejects duplicate name (case-insensitive)",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore registerSimple(state, "my-agent", #admin);

        let result = registerSimple(state, "MY-AGENT", #research);
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("An agent named \"my-agent\" is already registered.")
        );
      },
    );

    test(
      "stores provided llmModel and sources",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore AgentRegistryModel.register(
          "info-bot",
          #research,
          #groq(#gpt_oss_120b),
          [],
          ["web-search"],
          Map.empty<Text, AgentRegistryModel.ToolState>(),
          ["https://docs.example.com"],
          state,
        );

        switch (AgentRegistryModel.lookupByName("info-bot", state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?record) {
            expect.nat(record.toolsAllowed.size()).equal(1);
            expect.text(record.toolsAllowed[0]).equal("web-search");
            expect.nat(record.sources.size()).equal(1);
            expect.text(record.sources[0]).equal("https://docs.example.com");
          };
        };
      },
    );

    test(
      "accepts name with hyphens and digits",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = registerSimple(state, "agent-42", #communication);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
      },
    );
  },
);

// ============================================
// Suite: lookupById / lookupByName
// ============================================

suite(
  "AgentRegistryModel - lookupById and lookupByName",
  func() {

    test(
      "lookupById returns null for non-existent agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        expect.bool(isNoneRecord(AgentRegistryModel.lookupById(999, state))).equal(true);
      },
    );

    test(
      "lookupByName returns null for non-existent agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        expect.bool(isNoneRecord(AgentRegistryModel.lookupByName("ghost", state))).equal(true);
      },
    );

    test(
      "lookupById returns registered agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "planner", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        expect.bool(isSomeRecord(AgentRegistryModel.lookupById(id, state))).equal(true);
      },
    );

    test(
      "lookupByName is case-insensitive",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore registerSimple(state, "planner", #admin);

        expect.bool(isSomeRecord(AgentRegistryModel.lookupByName("PLANNER", state))).equal(true);
        expect.bool(isSomeRecord(AgentRegistryModel.lookupByName("Planner", state))).equal(true);
        expect.bool(isSomeRecord(AgentRegistryModel.lookupByName("planner", state))).equal(true);
      },
    );
  },
);

// ============================================
// Suite: updateById
// ============================================

suite(
  "AgentRegistryModel - updateById",
  func() {

    test(
      "updates llmModel",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentRegistryModel.updateById(
          id,
          null,
          null,
          ?#groq(#gpt_oss_120b),
          null,
          null,
          null,
          null,
          state,
        );
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            let isGroq = switch (r.llmModel) {
              case (#groq(_)) true;
            };
            expect.bool(isGroq).equal(true);
          };
        };
      },
    );

    test(
      "updates category",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        ignore AgentRegistryModel.updateById(id, null, ?#research, null, null, null, null, null, state);

        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.bool(r.category == #research).equal(true) };
        };
      },
    );

    test(
      "updates name and maintains index consistency",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "old-bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Update name to new-bot
        let result = AgentRegistryModel.updateById(id, ?"new-bot", null, null, null, null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        // Old name should no longer resolve
        expect.bool(isNoneRecord(AgentRegistryModel.lookupByName("old-bot", state))).equal(true);

        // New name should resolve to the same agent
        switch (AgentRegistryModel.lookupByName("new-bot", state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.nat(r.id).equal(id) };
        };

        // Lookup by ID should show updated name
        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.name).equal("new-bot") };
        };
      },
    );

    test(
      "rejects duplicate name when updating",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id1 = switch (registerSimple(state, "bot-one", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };
        ignore registerSimple(state, "bot-two", #research);

        // Try to rename bot-one to bot-two (which already exists)
        let result = AgentRegistryModel.updateById(id1, ?"bot-two", null, null, null, null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();

        // bot-one should still have its original name
        switch (AgentRegistryModel.lookupById(id1, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.name).equal("bot-one") };
        };
      },
    );

    test(
      "allows same agent to keep its name (no-op)",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Update with the same name (case variation)
        let result = AgentRegistryModel.updateById(id, ?"BOT", null, null, null, null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        // Lookup should still work
        expect.bool(isSomeRecord(AgentRegistryModel.lookupByName("bot", state))).equal(true);
      },
    );

    test(
      "rejects invalid name format when updating",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "valid-bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        // Try to update with invalid name (starting with digit)
        let result = AgentRegistryModel.updateById(id, ?"1invalid", null, null, null, null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();

        // Original name should still be intact
        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) { expect.text(r.name).equal("valid-bot") };
        };
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = AgentRegistryModel.updateById(999, null, null, null, null, null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: updateToolState
// ============================================

suite(
  "AgentRegistryModel - updateToolState",
  func() {

    test(
      "adds a new tool state entry",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let ts : AgentRegistryModel.ToolState = {
          usageCount = 3;
          knowHow = "use POST endpoint";
        };
        let result = AgentRegistryModel.updateToolState(id, "web-search", ts, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            switch (Map.get(r.toolsState, Text.compare, "web-search")) {
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
        let state = AgentRegistryModel.emptyState();
        let result = AgentRegistryModel.updateToolState(
          999,
          "tool",
          AgentRegistryModel.newToolState(),
          state,
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
  "AgentRegistryModel - secretsAllowed",
  func() {

    test(
      "registers with empty secretsAllowed by default",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore registerSimple(state, "bot", #admin);

        switch (AgentRegistryModel.lookupByName("bot", state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.secretsAllowed.size()).equal(0);
          };
        };
      },
    );

    test(
      "registers with explicit secretsAllowed entries",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore AgentRegistryModel.register(
          "secure-bot",
          #admin,
          #groq(#gpt_oss_120b),
          [(1, #groqApiKey), (2, #openaiApiKey)],
          [],
          Map.empty<Text, AgentRegistryModel.ToolState>(),
          [],
          state,
        );

        switch (AgentRegistryModel.lookupByName("secure-bot", state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.secretsAllowed.size()).equal(2);
          };
        };
      },
    );

    test(
      "updateById replaces secretsAllowed",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentRegistryModel.updateById(id, null, null, null, ?[(0, #groqApiKey)], null, null, null, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.secretsAllowed.size()).equal(1);
          };
        };
      },
    );

    test(
      "updateById clears secretsAllowed when passed empty array",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore AgentRegistryModel.register(
          "bot",
          #admin,
          #groq(#gpt_oss_120b),
          [(1, #groqApiKey)],
          [],
          Map.empty<Text, AgentRegistryModel.ToolState>(),
          [],
          state,
        );
        let id = 0;

        ignore AgentRegistryModel.updateById(id, null, null, null, ?[], null, null, null, state);

        switch (AgentRegistryModel.lookupById(id, state)) {
          case (null) { expect.bool(false).equal(true) };
          case (?r) {
            expect.nat(r.secretsAllowed.size()).equal(0);
          };
        };
      },
    );
  },
);

// ============================================
// Suite: unregisterById
// ============================================

suite(
  "AgentRegistryModel - unregisterById",
  func() {

    test(
      "removes a registered agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "bot", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };

        let result = AgentRegistryModel.unregisterById(id, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));
        expect.bool(isNoneRecord(AgentRegistryModel.lookupById(id, state))).equal(true);
        expect.bool(isNoneRecord(AgentRegistryModel.lookupByName("bot", state))).equal(true);
        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let state = AgentRegistryModel.emptyState();
        let result = AgentRegistryModel.unregisterById(999, state);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).isErr();
      },
    );
  },
);

// ============================================
// Suite: listAgents
// ============================================

suite(
  "AgentRegistryModel - listAgents",
  func() {

    test(
      "returns empty array for empty state",
      func() {
        let state = AgentRegistryModel.emptyState();
        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(0);
      },
    );

    test(
      "returns all registered agents",
      func() {
        let state = AgentRegistryModel.emptyState();
        ignore registerSimple(state, "alpha", #admin);
        ignore registerSimple(state, "beta", #research);
        ignore registerSimple(state, "gamma", #communication);

        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(3);
      },
    );

    test(
      "does not include unregistered agents",
      func() {
        let state = AgentRegistryModel.emptyState();
        let id = switch (registerSimple(state, "alpha", #admin)) {
          case (#ok n) n;
          case (#err _) { expect.bool(false).equal(true); 0 };
        };
        ignore registerSimple(state, "beta", #research);
        ignore AgentRegistryModel.unregisterById(id, state);

        expect.nat(AgentRegistryModel.listAgents(state).size()).equal(1);
      },
    );
  },
);
