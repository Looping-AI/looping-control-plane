import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import List "mo:core/List";
import Principal "mo:core/Principal";
import ValueStreamModel "../../../../src/open-org-backend/models/value-stream-model";

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

func resultUnitToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultUnitEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

func resultArrayValueStreamSizeEqual(r : Result.Result<[ValueStreamModel.ValueStream], Text>, expectedSize : Nat) : Bool {
  switch (r) {
    case (#ok arr) { arr.size() == expectedSize };
    case (#err _) { false };
  };
};

// Test data
func createValidInput() : ValueStreamModel.ValueStreamInput {
  {
    name = "Test Stream";
    problem = "Test problem statement";
    goal = "Test goal statement";
  };
};

// Test data for plans
func createValidPlanInput() : ValueStreamModel.PlanInput {
  {
    summary = "Test plan summary";
    currentState = "Starting point";
    targetState = "Desired end state";
    steps = "1. Step one\n2. Step two";
    risks = "Risk A: mitigation A";
    resources = "Resource X, Y, Z";
  };
};

suite(
  "ValueStreamModel - Workspace State",
  func() {
    test(
      "emptyWorkspaceState creates state with nextId 0",
      func() {
        let state = ValueStreamModel.emptyWorkspaceState();
        expect.nat(state.nextId).equal(0);
      },
    );

    test(
      "emptyValueStreamsMap creates empty map",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let streams = ValueStreamModel.listValueStreams(map, 0);
        // Empty map returns error for non-existent workspace
        expect.bool(Result.isErr(streams)).equal(true);
      },
    );
  },
);

suite(
  "ValueStreamModel - createValueStream",
  func() {
    test(
      "creates value stream with valid input",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let result = ValueStreamModel.createValueStream(map, 0, createValidInput());

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(0));

        let streams = ValueStreamModel.listValueStreams(map, 0);
        expect.bool(resultArrayValueStreamSizeEqual(streams, 1)).equal(true);
      },
    );

    test(
      "creates value stream with draft status",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) { expect.bool(s.status == #draft).equal(true) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "creates value stream with null plan",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            expect.bool(s.plan == null).equal(true);
            expect.nat(List.size(s.planHistory)).equal(0);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "increments ID for each new value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();

        let result1 = ValueStreamModel.createValueStream(map, 0, createValidInput());
        expect.result<Nat, Text>(result1, resultNatToText, resultNatEqual).equal(#ok(0));

        let input2 = { name = "Second"; problem = "Problem 2"; goal = "Goal 2" };
        let result2 = ValueStreamModel.createValueStream(map, 0, input2);
        expect.result<Nat, Text>(result2, resultNatToText, resultNatEqual).equal(#ok(1));

        let streams = ValueStreamModel.listValueStreams(map, 0);
        expect.bool(resultArrayValueStreamSizeEqual(streams, 2)).equal(true);
      },
    );

    test(
      "rejects empty name",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let input = { name = ""; problem = "Problem"; goal = "Goal" };
        let result = ValueStreamModel.createValueStream(map, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Value stream name cannot be empty.")
        );
      },
    );

    test(
      "rejects empty problem",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let input = { name = "Name"; problem = ""; goal = "Goal" };
        let result = ValueStreamModel.createValueStream(map, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Value stream problem cannot be empty.")
        );
      },
    );

    test(
      "rejects empty goal",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let input = { name = "Name"; problem = "Problem"; goal = "" };
        let result = ValueStreamModel.createValueStream(map, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Value stream goal cannot be empty.")
        );
      },
    );

    test(
      "maintains separate streams per workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();

        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());
        ignore ValueStreamModel.createValueStream(map, 1, createValidInput());

        let ws0Streams = ValueStreamModel.listValueStreams(map, 0);
        let ws1Streams = ValueStreamModel.listValueStreams(map, 1);

        expect.bool(resultArrayValueStreamSizeEqual(ws0Streams, 1)).equal(true);
        expect.bool(resultArrayValueStreamSizeEqual(ws1Streams, 1)).equal(true);
      },
    );

    test(
      "sets timestamps on creation",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            expect.bool(s.createdAt > 0).equal(true);
            expect.bool(s.updatedAt > 0).equal(true);
            expect.bool(s.createdAt == s.updatedAt).equal(true);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "ValueStreamModel - getValueStream",
  func() {
    test(
      "returns value stream when exists",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            expect.text(s.name).equal("Test Stream");
            expect.nat(s.workspaceId).equal(0);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let stream = ValueStreamModel.getValueStream(map, 999, 0);
        expect.bool(Result.isErr(stream)).equal(true);
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 999);
        expect.bool(Result.isErr(stream)).equal(true);
      },
    );
  },
);

suite(
  "ValueStreamModel - updateValueStream",
  func() {
    test(
      "updates name",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.updateValueStream(
          map,
          0,
          0,
          ?"Updated Name",
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) { expect.text(s.name).equal("Updated Name") };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates problem",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.updateValueStream(
          map,
          0,
          0,
          null,
          ?"New problem statement",
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            expect.text(s.problem).equal("New problem statement");
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates goal",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.updateValueStream(
          map,
          0,
          0,
          null,
          null,
          ?"New goal statement",
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) { expect.text(s.goal).equal("New goal statement") };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates status",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.updateValueStream(
          map,
          0,
          0,
          null,
          null,
          null,
          ?#active,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) { expect.bool(s.status == #active).equal(true) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "preserves createdAt timestamp",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let streamBefore = ValueStreamModel.getValueStream(map, 0, 0);
        let createdAtBefore = switch (streamBefore) {
          case (#ok(s)) { s.createdAt };
          case (#err(_)) { 0 };
        };

        ignore ValueStreamModel.updateValueStream(map, 0, 0, ?"New Name", null, null, null);

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) { expect.int(s.createdAt).equal(createdAtBefore) };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let result = ValueStreamModel.updateValueStream(
          map,
          999,
          0,
          ?"Name",
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.updateValueStream(
          map,
          0,
          999,
          ?"Name",
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Value stream not found.")
        );
      },
    );
  },
);

suite(
  "ValueStreamModel - deleteValueStream",
  func() {
    test(
      "deletes existing value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.deleteValueStream(map, 0, 0);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        expect.bool(Result.isErr(stream)).equal(true);
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let result = ValueStreamModel.deleteValueStream(map, 999, 0);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let result = ValueStreamModel.deleteValueStream(map, 0, 999);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Value stream not found.")
        );
      },
    );
  },
);

suite(
  "ValueStreamModel - listValueStreams",
  func() {
    test(
      "returns error for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let streams = ValueStreamModel.listValueStreams(map, 999);
        expect.bool(Result.isErr(streams)).equal(true);
      },
    );

    test(
      "returns all value streams in workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();

        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());
        ignore ValueStreamModel.createValueStream(map, 0, { name = "Second"; problem = "P2"; goal = "G2" });
        ignore ValueStreamModel.createValueStream(map, 0, { name = "Third"; problem = "P3"; goal = "G3" });

        let streams = ValueStreamModel.listValueStreams(map, 0);
        expect.bool(resultArrayValueStreamSizeEqual(streams, 3)).equal(true);
      },
    );
  },
);

suite(
  "ValueStreamModel - setPlan",
  func() {
    test(
      "creates plan when none exists",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");
        let result = ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Initial plan",
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            switch (s.plan) {
              case (null) { expect.bool(false).equal(true) };
              case (?p) {
                expect.text(p.summary).equal("Test plan summary");
                expect.text(p.currentState).equal("Starting point");
                expect.text(p.targetState).equal("Desired end state");
                expect.text(p.steps).equal("1. Step one\n2. Step two");
                expect.text(p.risks).equal("Risk A: mitigation A");
                expect.text(p.resources).equal("Resource X, Y, Z");
                expect.bool(p.createdAt > 0).equal(true);
                expect.bool(p.updatedAt > 0).equal(true);
              };
            };
            expect.nat(List.size(s.planHistory)).equal(1);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "updates existing plan",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");

        // Create initial plan
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Initial plan",
        );

        // Update plan
        let updatedInput : ValueStreamModel.PlanInput = {
          summary = "Updated summary";
          currentState = "New current state";
          targetState = "New target state";
          steps = "1. New step";
          risks = "New risks";
          resources = "New resources";
        };

        let result = ValueStreamModel.setPlan(
          map,
          0,
          0,
          updatedInput,
          #assistant("AI Agent"),
          "Updated approach",
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            switch (s.plan) {
              case (null) { expect.bool(false).equal(true) };
              case (?p) {
                expect.text(p.summary).equal("Updated summary");
                expect.text(p.currentState).equal("New current state");
              };
            };
            expect.nat(List.size(s.planHistory)).equal(2);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "preserves createdAt when updating plan",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");

        // Create initial plan
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Initial",
        );

        let stream1 = ValueStreamModel.getValueStream(map, 0, 0);
        let initialCreatedAt = switch (stream1) {
          case (#ok(s)) {
            switch (s.plan) {
              case (null) { 0 };
              case (?p) { p.createdAt };
            };
          };
          case (#err(_)) { 0 };
        };

        // Update plan
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Updated",
        );

        let stream2 = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream2) {
          case (#ok(s)) {
            switch (s.plan) {
              case (null) { expect.bool(false).equal(true) };
              case (?p) {
                expect.int(p.createdAt).equal(initialCreatedAt);
                expect.bool(p.updatedAt >= p.createdAt).equal(true);
              };
            };
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "records plan change in history",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Initial plan created",
        );

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            let history = List.toArray(s.planHistory);
            expect.nat(history.size()).equal(1);

            let change = history[0];
            expect.text(change.diff).equal("Initial plan created");
            expect.bool(change.timestamp > 0).equal(true);

            switch (change.changedBy) {
              case (#principal(p)) {
                expect.bool(p == principal).equal(true);
              };
              case (#assistant(_)) { expect.bool(false).equal(true) };
            };
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "supports clearing plan with empty strings",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");

        // Create plan
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Initial",
        );

        // Clear with empty strings
        let emptyInput : ValueStreamModel.PlanInput = {
          summary = "";
          currentState = "";
          targetState = "";
          steps = "";
          risks = "";
          resources = "";
        };

        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          emptyInput,
          #principal(principal),
          "Cleared plan",
        );

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            switch (s.plan) {
              case (null) { expect.bool(false).equal(true) };
              case (?p) {
                expect.text(p.summary).equal("");
                expect.text(p.steps).equal("");
              };
            };
            expect.nat(List.size(s.planHistory)).equal(2);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let principal = Principal.fromText("aaaaa-aa");

        let result = ValueStreamModel.setPlan(
          map,
          999,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Test",
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");

        let result = ValueStreamModel.setPlan(
          map,
          0,
          999,
          createValidPlanInput(),
          #principal(principal),
          "Test",
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Value stream not found.")
        );
      },
    );
  },
);

suite(
  "ValueStreamModel - toShareable",
  func() {
    test(
      "converts ValueStream to ShareableValueStream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let principal = Principal.fromText("aaaaa-aa");
        ignore ValueStreamModel.setPlan(
          map,
          0,
          0,
          createValidPlanInput(),
          #principal(principal),
          "Test plan",
        );

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (#ok(s)) {
            let shareable = ValueStreamModel.toShareable(s);

            expect.nat(shareable.id).equal(s.id);
            expect.text(shareable.name).equal(s.name);
            expect.bool(shareable.plan != null).equal(true);
            expect.nat(shareable.planHistory.size()).equal(1);
          };
          case (#err(_)) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);
