import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
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

// Test data
func createValidInput() : ValueStreamModel.ValueStreamInput {
  {
    name = "Test Stream";
    problem = "Test problem statement";
    goal = "Test goal statement";
  };
};

suite(
  "ValueStreamModel - Workspace State",
  func() {
    test(
      "emptyWorkspaceState creates state with nextId 0",
      func() {
        let (nextId, _) = ValueStreamModel.emptyWorkspaceState();
        expect.nat(nextId).equal(0);
      },
    );

    test(
      "emptyValueStreamsMap creates empty map",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let streams = ValueStreamModel.listValueStreams(map, 0);
        expect.nat(streams.size()).equal(0);
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
        expect.nat(streams.size()).equal(1);
      },
    );

    test(
      "creates value stream with draft status",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (?s) { expect.bool(s.status == #draft).equal(true) };
          case (null) { expect.bool(false).equal(true) };
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
        expect.nat(streams.size()).equal(2);
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

        expect.nat(ws0Streams.size()).equal(1);
        expect.nat(ws1Streams.size()).equal(1);
      },
    );

    test(
      "sets timestamps on creation",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (?s) {
            expect.bool(s.createdAt > 0).equal(true);
            expect.bool(s.updatedAt > 0).equal(true);
            expect.bool(s.createdAt == s.updatedAt).equal(true);
          };
          case (null) { expect.bool(false).equal(true) };
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
          case (?s) {
            expect.text(s.name).equal("Test Stream");
            expect.nat(s.workspaceId).equal(0);
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns null for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let stream = ValueStreamModel.getValueStream(map, 999, 0);
        expect.bool(stream == null).equal(true);
      },
    );

    test(
      "returns null for non-existent value stream",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        ignore ValueStreamModel.createValueStream(map, 0, createValidInput());

        let stream = ValueStreamModel.getValueStream(map, 0, 999);
        expect.bool(stream == null).equal(true);
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
          case (?s) { expect.text(s.name).equal("Updated Name") };
          case (null) { expect.bool(false).equal(true) };
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
          case (?s) { expect.text(s.problem).equal("New problem statement") };
          case (null) { expect.bool(false).equal(true) };
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
          case (?s) { expect.text(s.goal).equal("New goal statement") };
          case (null) { expect.bool(false).equal(true) };
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
          case (?s) { expect.bool(s.status == #active).equal(true) };
          case (null) { expect.bool(false).equal(true) };
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
          case (?s) { s.createdAt };
          case (null) { 0 };
        };

        ignore ValueStreamModel.updateValueStream(map, 0, 0, ?"New Name", null, null, null);

        let stream = ValueStreamModel.getValueStream(map, 0, 0);
        switch (stream) {
          case (?s) { expect.int(s.createdAt).equal(createdAtBefore) };
          case (null) { expect.bool(false).equal(true) };
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
        expect.bool(stream == null).equal(true);
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
      "returns empty array for non-existent workspace",
      func() {
        let map = ValueStreamModel.emptyValueStreamsMap();
        let streams = ValueStreamModel.listValueStreams(map, 999);
        expect.nat(streams.size()).equal(0);
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
        expect.nat(streams.size()).equal(3);
      },
    );
  },
);
