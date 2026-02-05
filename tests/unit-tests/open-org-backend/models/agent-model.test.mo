import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import AgentModel "../../../../src/open-org-backend/models/agent-model";

// Helper functions for Result comparison
func resultNatToText(r : Result.Result<Nat, Text>) : Text {
  switch (r) {
    case (#ok n) { "#ok(" # Nat.toText(n) # ")" };
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

suite(
  "AgentModel - createAgent",
  func() {
    test(
      "creates agent with valid input",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let result = AgentModel.createAgent(
          "TestAgent",
          #groq,
          "llama-3.1-70b-versatile",
          workspaceState,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).isOk();
        expect.nat(workspaceState.nextId).equal(1);

        // Verify agent was added
        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) {
            expect.text(a.name).equal("TestAgent");
            expect.text(a.model).equal("llama-3.1-70b-versatile");
          };
          case (null) {
            expect.bool(false).equal(true); // Force fail
          };
        };
      },
    );

    test(
      "rejects empty agent name",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let result = AgentModel.createAgent(
          "",
          #groq,
          "llama-3.1-70b-versatile",
          workspaceState,
        );

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Agent name cannot be empty.")
        );
        expect.nat(workspaceState.nextId).equal(0); // ID should not increment
      },
    );

    test(
      "increments ID for each new agent",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();

        let result1 = AgentModel.createAgent("Agent1", #groq, "model1", workspaceState);
        expect.result<Nat, Text>(result1, resultNatToText, resultNatEqual).equal(#ok(0));
        expect.nat(workspaceState.nextId).equal(1);

        let result2 = AgentModel.createAgent("Agent2", #openai, "model2", workspaceState);
        expect.result<Nat, Text>(result2, resultNatToText, resultNatEqual).equal(#ok(1));
        expect.nat(workspaceState.nextId).equal(2);

        let result3 = AgentModel.createAgent("Agent3", #groq, "model3", workspaceState);
        expect.result<Nat, Text>(result3, resultNatToText, resultNatEqual).equal(#ok(2));
        expect.nat(workspaceState.nextId).equal(3);
      },
    );
  },
);

suite(
  "AgentModel - getAgent",
  func() {
    test(
      "returns agent when exists",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("TestAgent", #groq, "test-model", workspaceState);

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) {
            expect.text(a.name).equal("TestAgent");
            expect.nat(a.id).equal(0);
          };
          case (null) {
            expect.bool(false).equal(true);
          };
        };
      },
    );

    test(
      "returns null for non-existent agent",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let agent = AgentModel.getAgent(999, workspaceState);
        expect.bool(agent == null).equal(true);
      },
    );
  },
);

suite(
  "AgentModel - updateAgent",
  func() {
    test(
      "updates agent name",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("OldName", #groq, "model", workspaceState);

        let result = AgentModel.updateAgent(0, ?"NewName", null, null, workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) { expect.text(a.name).equal("NewName") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates agent model",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("Agent", #groq, "old-model", workspaceState);

        let result = AgentModel.updateAgent(0, null, null, ?"new-model", workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) { expect.text(a.model).equal("new-model") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates agent provider",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("Agent", #groq, "model", workspaceState);

        let result = AgentModel.updateAgent(0, null, ?#openai, null, workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) { expect.bool(a.provider == #openai).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates multiple fields at once",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("OldAgent", #groq, "old-model", workspaceState);

        let result = AgentModel.updateAgent(0, ?"NewAgent", ?#openai, ?"new-model", workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) {
            expect.text(a.name).equal("NewAgent");
            expect.text(a.model).equal("new-model");
            expect.bool(a.provider == #openai).equal(true);
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let result = AgentModel.updateAgent(999, ?"Name", null, null, workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("Agent not found.")
        );
      },
    );

    test(
      "preserves unchanged fields when updating",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("OriginalName", #groq, "original-model", workspaceState);

        // Only update the name
        ignore AgentModel.updateAgent(0, ?"UpdatedName", null, null, workspaceState);

        let agent = AgentModel.getAgent(0, workspaceState);
        switch (agent) {
          case (?a) {
            expect.text(a.name).equal("UpdatedName");
            expect.text(a.model).equal("original-model"); // Unchanged
            expect.bool(a.provider == #groq).equal(true); // Unchanged
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "AgentModel - deleteAgent",
  func() {
    test(
      "deletes existing agent",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        ignore AgentModel.createAgent("ToDelete", #groq, "model", workspaceState);

        // Verify agent exists
        expect.bool(AgentModel.getAgent(0, workspaceState) != null).equal(true);

        let result = AgentModel.deleteAgent(0, workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(#ok(true));

        // Verify agent is gone
        expect.bool(AgentModel.getAgent(0, workspaceState) == null).equal(true);
      },
    );

    test(
      "returns error for non-existent agent",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let result = AgentModel.deleteAgent(999, workspaceState);
        expect.result<Bool, Text>(result, resultBoolToText, resultBoolEqual).equal(
          #err("Agent not found.")
        );
      },
    );
  },
);

suite(
  "AgentModel - listAgents",
  func() {
    test(
      "returns empty array for no agents",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();
        let list = AgentModel.listAgents(workspaceState);
        expect.nat(list.size()).equal(0);
      },
    );

    test(
      "returns all agents",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();

        ignore AgentModel.createAgent("Agent1", #groq, "model1", workspaceState);
        ignore AgentModel.createAgent("Agent2", #openai, "model2", workspaceState);
        ignore AgentModel.createAgent("Agent3", #groq, "model3", workspaceState);

        let list = AgentModel.listAgents(workspaceState);
        expect.nat(list.size()).equal(3);
      },
    );

    test(
      "does not include deleted agents",
      func() {
        let workspaceState = AgentModel.emptyWorkspaceState();

        ignore AgentModel.createAgent("Agent1", #groq, "model1", workspaceState);
        ignore AgentModel.createAgent("Agent2", #openai, "model2", workspaceState);

        // Delete first agent
        ignore AgentModel.deleteAgent(0, workspaceState);

        let list = AgentModel.listAgents(workspaceState);
        expect.nat(list.size()).equal(1);
      },
    );
  },
);
