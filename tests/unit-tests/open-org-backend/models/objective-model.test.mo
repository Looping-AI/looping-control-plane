import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import ObjectiveModel "../../../../src/open-org-backend/models/objective-model";

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

func resultObjectiveToText(r : Result.Result<ObjectiveModel.Objective, Text>) : Text {
  switch (r) {
    case (#ok o) { "#ok(" # o.name # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultObjectiveEqual(r1 : Result.Result<ObjectiveModel.Objective, Text>, r2 : Result.Result<ObjectiveModel.Objective, Text>) : Bool {
  switch (r1, r2) {
    case (#err(e1), #err(e2)) { e1 == e2 };
    case (#ok(o1), #ok(o2)) { o1.id == o2.id };
    case (_, _) { false };
  };
};

func resultObjectivesToText(r : Result.Result<[ObjectiveModel.Objective], Text>) : Text {
  switch (r) {
    case (#ok arr) { "#ok(size=" # Nat.toText(arr.size()) # ")" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultObjectivesEqual(r1 : Result.Result<[ObjectiveModel.Objective], Text>, r2 : Result.Result<[ObjectiveModel.Objective], Text>) : Bool {
  switch (r1, r2) {
    case (#err(e1), #err(e2)) { e1 == e2 };
    case (#ok(a1), #ok(a2)) { a1.size() == a2.size() };
    case (_, _) { false };
  };
};

// Helper to unwrap objective result
func unwrapObjective(r : Result.Result<ObjectiveModel.Objective, Text>) : ObjectiveModel.Objective {
  switch (r) {
    case (#ok o) { o };
    case (#err _) {
      // This will fail tests correctly if called on an error
      {
        id = 0;
        name = "";
        description = null;
        objectiveType = #target;
        metricIds = [];
        computation = "";
        target = #boolean(false);
        targetDate = null;
        current = null;
        history = List.empty<ObjectiveModel.ObjectiveDatapoint>();
        impactReviews = List.empty<ObjectiveModel.ImpactReview>();
        status = #active;
        createdAt = 0;
        updatedAt = 0;
      };
    };
  };
};

// Helper to get history as array for easier testing
func getHistoryArray(o : ObjectiveModel.Objective) : [ObjectiveModel.ObjectiveDatapoint] {
  List.toArray(o.history);
};

// Helper to unwrap objectives array result
func unwrapObjectives(r : Result.Result<[ObjectiveModel.Objective], Text>) : [ObjectiveModel.Objective] {
  switch (r) {
    case (#ok arr) { arr };
    case (#err _) { [] };
  };
};

// Test data
func createValidObjectiveInput() : ObjectiveModel.ObjectiveInput {
  {
    name = "Test Objective";
    description = ?"Test description";
    objectiveType = #target;
    metricIds = [0, 1];
    computation = "metric:0";
    target = #count({ target = 100.0; direction = #increase });
    targetDate = null;
  };
};

suite(
  "ObjectiveModel - State Helpers",
  func() {
    test(
      "emptyObjectivesMap creates empty map",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        let result = ObjectiveModel.listObjectives(map, 0, 0);
        expect.result<[ObjectiveModel.Objective], Text>(result, resultObjectivesToText, resultObjectivesEqual).equal(
          #err("Workspace not found.")
        );
      },
    );
  },
);

suite(
  "ObjectiveModel - addObjective",
  func() {
    test(
      "adds objective with valid input",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let result = ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(0));

        let objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 0));
        expect.nat(objectives.size()).equal(1);
      },
    );

    test(
      "creates objective with active status",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.getObjective(map, 0, 0, 0);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).isOk();
        let o = unwrapObjective(result);
        expect.bool(o.status == #active).equal(true);
      },
    );

    test(
      "increments ID for each new objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        let result1 = ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        expect.result<Nat, Text>(result1, resultNatToText, resultNatEqual).equal(#ok(0));

        let result2 = ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        expect.result<Nat, Text>(result2, resultNatToText, resultNatEqual).equal(#ok(1));

        let objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 0));
        expect.nat(objectives.size()).equal(2);
      },
    );

    test(
      "maintains separate objectives per value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ObjectiveModel.initValueStreamObjectives(map, 0, 1);

        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 0, 1, createValidObjectiveInput());

        let vs0Objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 0));
        let vs1Objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 1));

        expect.nat(vs0Objectives.size()).equal(1);
        expect.nat(vs1Objectives.size()).equal(1);
      },
    );

    test(
      "maintains separate objectives per workspace",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ObjectiveModel.initValueStreamObjectives(map, 1, 0);

        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 1, 0, createValidObjectiveInput());

        let ws0Objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 0));
        let ws1Objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 1, 0));

        expect.nat(ws0Objectives.size()).equal(1);
        expect.nat(ws1Objectives.size()).equal(1);
      },
    );

    test(
      "rejects empty name",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "metric:0";
          target = #boolean(true);
          targetDate = null;
        };

        let result = ObjectiveModel.addObjective(map, 0, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Objective name cannot be empty.")
        );
      },
    );

    test(
      "rejects empty metricIds",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Test";
          description = null;
          objectiveType = #target;
          metricIds = [];
          computation = "metric:0";
          target = #boolean(true);
          targetDate = null;
        };

        let result = ObjectiveModel.addObjective(map, 0, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Objective must have at least one metric.")
        );
      },
    );

    test(
      "rejects empty computation",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Test";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "";
          target = #boolean(true);
          targetDate = null;
        };

        let result = ObjectiveModel.addObjective(map, 0, 0, input);

        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Objective computation cannot be empty.")
        );
      },
    );

    test(
      "sets timestamps on creation",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.getObjective(map, 0, 0, 0);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).isOk();
        let o = unwrapObjective(result);
        expect.bool(o.createdAt > 0).equal(true);
        expect.bool(o.updatedAt > 0).equal(true);
        expect.bool(o.createdAt == o.updatedAt).equal(true);
      },
    );
  },
);

suite(
  "ObjectiveModel - getObjective",
  func() {
    test(
      "returns objective when exists",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.getObjective(map, 0, 0, 0);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).isOk();
        let o = unwrapObjective(result);
        expect.text(o.name).equal("Test Objective");
        expect.nat(o.id).equal(0);
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        let result = ObjectiveModel.getObjective(map, 999, 0, 0);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.getObjective(map, 0, 999, 0);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).equal(
          #err("Value stream not found.")
        );
      },
    );

    test(
      "returns error for non-existent objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.getObjective(map, 0, 0, 999);
        expect.result<ObjectiveModel.Objective, Text>(result, resultObjectiveToText, resultObjectiveEqual).equal(
          #err("Objective not found.")
        );
      },
    );
  },
);

suite(
  "ObjectiveModel - updateObjective",
  func() {
    test(
      "updates name",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          0,
          0,
          ?"Updated Objective",
          null,
          null,
          null,
          null,
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.text(o.name).equal("Updated Objective");
      },
    );

    test(
      "updates metricIds",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          0,
          0,
          null,
          null,
          null,
          ?[5, 6, 7],
          null,
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.nat(o.metricIds.size()).equal(3);
        expect.nat(o.metricIds[0]).equal(5);
      },
    );

    test(
      "updates computation",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          0,
          0,
          null,
          null,
          null,
          null,
          ?"metric:5 + metric:6",
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.text(o.computation).equal("metric:5 + metric:6");
      },
    );

    test(
      "updates status",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          0,
          0,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          ?#paused,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.bool(o.status == #paused).equal(true);
      },
    );

    test(
      "returns error for non-existent objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          0,
          999,
          ?"Name",
          null,
          null,
          null,
          null,
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Objective not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        // Initialize workspace 0 with value stream 0, but not 999
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        let result = ObjectiveModel.updateObjective(
          map,
          0,
          999,
          0,
          ?"Name",
          null,
          null,
          null,
          null,
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Value stream not found.")
        );
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();

        let result = ObjectiveModel.updateObjective(
          map,
          999,
          0,
          0,
          ?"Name",
          null,
          null,
          null,
          null,
          null,
          null,
          null,
        );

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );
  },
);

suite(
  "ObjectiveModel - archiveObjective",
  func() {
    test(
      "archives objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.archiveObjective(map, 0, 0, 0);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.bool(o.status == #archived).equal(true);
      },
    );
  },
);

suite(
  "ObjectiveModel - recordObjectiveDatapoint",
  func() {
    test(
      "records datapoint and updates current",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?75.5;
          valueWarning = null;
          comments = [];
        };

        let result = ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, datapoint);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        switch (o.current) {
          case (?c) { expect.bool(c == 75.5).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "adds all datapoints to history",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        // First datapoint
        let dp1 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp1);

        // Second datapoint
        let dp2 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 2_000_000_000;
          value = ?75.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp2);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        // Both datapoints should be in history
        expect.nat(List.size(o.history)).equal(2);
        // Current should be the latest value
        switch (o.current) {
          case (?c) { expect.bool(c == 75.0).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
        // First history entry should be dp1
        let history = List.toArray(o.history);
        switch (history[0].value) {
          case (?v) { expect.bool(v == 50.0).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "handles null value with warning",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = null;
          valueWarning = ?"Metric unavailable";
          comments = [];
        };

        let result = ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, datapoint);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.bool(o.current == null).equal(true);
        expect.nat(List.size(o.history)).equal(1); // Null datapoint goes to history
      },
    );

    test(
      "records datapoint when current is null and new value is null",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        // Current starts as null, record a null datapoint
        let dp1 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = null;
          valueWarning = ?"First null measurement";
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp1);

        // Record another null datapoint
        let dp2 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 2_000_000_000;
          value = null;
          valueWarning = ?"Second null measurement";
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp2);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        // Both null datapoints should be in history
        expect.nat(List.size(o.history)).equal(2);
        // Current should still be null
        expect.bool(o.current == null).equal(true);
        // History should contain both entries with their warnings
        let history = List.toArray(o.history);
        expect.option<Text>(history[0].valueWarning, func(a) { a }, Text.equal).equal(?"First null measurement");
        expect.option<Text>(history[1].valueWarning, func(a) { a }, Text.equal).equal(?"Second null measurement");
      },
    );

    test(
      "returns error for non-existent objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };

        let result = ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 999, datapoint);

        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Objective not found.")
        );
      },
    );
  },
);

suite(
  "ObjectiveModel - listObjectives",
  func() {
    test(
      "returns error for non-existent workspace",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        let result = ObjectiveModel.listObjectives(map, 999, 0);
        expect.result<[ObjectiveModel.Objective], Text>(result, resultObjectivesToText, resultObjectivesEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let result = ObjectiveModel.listObjectives(map, 0, 999);
        expect.result<[ObjectiveModel.Objective], Text>(result, resultObjectivesToText, resultObjectivesEqual).equal(
          #err("Value stream not found.")
        );
      },
    );

    test(
      "returns all objectives for value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 0));
        expect.nat(objectives.size()).equal(3);
      },
    );
  },
);

suite(
  "ObjectiveModel - deleteValueStreamObjectives",
  func() {
    test(
      "deletes all objectives for value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        ObjectiveModel.deleteValueStreamObjectives(map, 0, 0);

        // After deletion, the value stream state is removed, so we get an error
        let result = ObjectiveModel.listObjectives(map, 0, 0);
        expect.result<[ObjectiveModel.Objective], Text>(result, resultObjectivesToText, resultObjectivesEqual).equal(
          #err("Value stream not found.")
        );
      },
    );

    test(
      "does not affect other value streams",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ObjectiveModel.initValueStreamObjectives(map, 0, 1);

        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        ignore ObjectiveModel.addObjective(map, 0, 1, createValidObjectiveInput());

        ObjectiveModel.deleteValueStreamObjectives(map, 0, 0);

        // Value stream 0 is deleted
        let vs0Result = ObjectiveModel.listObjectives(map, 0, 0);
        expect.result<[ObjectiveModel.Objective], Text>(vs0Result, resultObjectivesToText, resultObjectivesEqual).equal(
          #err("Value stream not found.")
        );

        // Value stream 1 still has objectives
        let vs1Objectives = unwrapObjectives(ObjectiveModel.listObjectives(map, 0, 1));
        expect.nat(vs1Objectives.size()).equal(1);
      },
    );
  },
);

suite(
  "ObjectiveModel - addDatapointComment",
  func() {
    test(
      "adds comment to datapoint",
      func() {
        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };

        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_001;
          author = #assistant("gpt-4");
          message = "Looking good!";
        };

        let updated = ObjectiveModel.addDatapointComment(datapoint, comment);

        expect.nat(updated.comments.size()).equal(1);
        expect.text(updated.comments[0].message).equal("Looking good!");
      },
    );

    test(
      "preserves existing comments",
      func() {
        let existingComment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_000;
          author = #task("task-1");
          message = "First comment";
        };

        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [existingComment];
        };

        let newComment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_001;
          author = #assistant("claude");
          message = "Second comment";
        };

        let updated = ObjectiveModel.addDatapointComment(datapoint, newComment);

        expect.nat(updated.comments.size()).equal(2);
        expect.text(updated.comments[0].message).equal("First comment");
        expect.text(updated.comments[1].message).equal("Second comment");
      },
    );

    test(
      "supports principal as author",
      func() {
        let datapoint : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };

        let testPrincipal = Principal.fromText("aaaaa-aa");
        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_001;
          author = #principal(testPrincipal);
          message = "User comment";
        };

        let updated = ObjectiveModel.addDatapointComment(datapoint, comment);

        expect.nat(updated.comments.size()).equal(1);
        switch (updated.comments[0].author) {
          case (#principal(p)) { expect.bool(p == testPrincipal).equal(true) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "ObjectiveModel - addCommentToHistoryDatapoint",
  func() {
    test(
      "full flow: creates objective, records datapoints, adds comment to history, and persists",
      func() {
        // Step 1: Create objectives map and initialize value stream
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        // Step 2: Add an objective
        let addResult = ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());
        expect.result<Nat, Text>(addResult, resultNatToText, resultNatEqual).equal(#ok(0));

        // Step 3: Record first datapoint (goes to history, sets current)
        let dp1 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp1);

        // Step 4: Record second datapoint (also goes to history, updates current)
        let dp2 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 2_000_000_000;
          value = ?75.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp2);

        // Verify history has 2 entries (all datapoints go to history)
        let o1 = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        let h1 = getHistoryArray(o1);
        expect.nat(h1.size()).equal(2);
        expect.nat(h1[0].comments.size()).equal(0);

        // Step 5: Add a comment to the first history datapoint at index 0
        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 3_000_000_000;
          author = #assistant("gpt-4");
          message = "Good progress on this metric!";
        };

        let commentResult = ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 0, 0, 0, comment);
        expect.result<(), Text>(commentResult, resultUnitToText, resultUnitEqual).isOk();

        // Step 6: Verify the comment is persisted in the map
        let o2 = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        let h2 = getHistoryArray(o2);
        expect.nat(h2.size()).equal(2);
        expect.nat(h2[0].comments.size()).equal(1);
        expect.text(h2[0].comments[0].message).equal("Good progress on this metric!");

        // Step 7: Add another comment to the same datapoint
        let comment2 : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 4_000_000_000;
          author = #task("analysis-task");
          message = "This aligns with our Q1 target.";
        };

        let commentResult2 = ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 0, 0, 0, comment2);
        expect.result<(), Text>(commentResult2, resultUnitToText, resultUnitEqual).isOk();

        // Verify both comments are persisted
        let o3 = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        let h3 = getHistoryArray(o3);
        expect.nat(h3[0].comments.size()).equal(2);
        expect.text(h3[0].comments[0].message).equal("Good progress on this metric!");
        expect.text(h3[0].comments[1].message).equal("This aligns with our Q1 target.");
      },
    );

    test(
      "returns error for non-existent workspace",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();

        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_000;
          author = #assistant("gpt-4");
          message = "Test";
        };

        let result = ObjectiveModel.addCommentToHistoryDatapoint(map, 999, 0, 0, 0, comment);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "returns error for non-existent value stream",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);

        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_000;
          author = #assistant("gpt-4");
          message = "Test";
        };

        let result = ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 999, 0, 0, comment);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Value stream not found.")
        );
      },
    );

    test(
      "returns error for non-existent objective",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 1_000_000_000;
          author = #assistant("gpt-4");
          message = "Test";
        };

        let result = ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 0, 999, 0, comment);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Objective not found.")
        );
      },
    );

    test(
      "returns error for non-existent history index",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        // Record a datapoint to create history
        let dp1 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp1);

        // Record another to move first to history
        let dp2 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 2_000_000_000;
          value = ?75.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp2);

        // Try to add comment to non-existent history index
        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 3_000_000_000;
          author = #assistant("gpt-4");
          message = "Test";
        };

        let result = ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 0, 0, 999, comment);
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("History datapoint not found.")
        );
      },
    );

    test(
      "does not update objective updatedAt when adding comment",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        ignore ObjectiveModel.addObjective(map, 0, 0, createValidObjectiveInput());

        // Record datapoints
        let dp1 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 1_000_000_000;
          value = ?50.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp1);

        let dp2 : ObjectiveModel.ObjectiveDatapoint = {
          timestamp = 2_000_000_000;
          value = ?75.0;
          valueWarning = null;
          comments = [];
        };
        ignore ObjectiveModel.recordObjectiveDatapoint(map, 0, 0, 0, dp2);

        // Get updatedAt before adding comment
        let o1 = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        let updatedAtBefore = o1.updatedAt;

        // Add comment
        let comment : ObjectiveModel.ObjectiveDatapointComment = {
          timestamp = 3_000_000_000;
          author = #assistant("gpt-4");
          message = "Test";
        };
        ignore ObjectiveModel.addCommentToHistoryDatapoint(map, 0, 0, 0, 0, comment);

        // Verify updatedAt is unchanged
        let o2 = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        expect.bool(o2.updatedAt == updatedAtBefore).equal(true);
      },
    );
  },
);

suite(
  "ObjectiveModel - Target Types",
  func() {
    test(
      "supports percentage target",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Percentage Test";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "metric:0";
          target = #percentage({ target = 95.0 });
          targetDate = null;
        };

        ignore ObjectiveModel.addObjective(map, 0, 0, input);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        switch (o.target) {
          case (#percentage({ target })) {
            expect.bool(target == 95.0).equal(true);
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "supports count target with increase direction",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Count Test";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "metric:0";
          target = #count({ target = 1000.0; direction = #increase });
          targetDate = null;
        };

        ignore ObjectiveModel.addObjective(map, 0, 0, input);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        switch (o.target) {
          case (#count({ target; direction })) {
            expect.bool(target == 1000.0).equal(true);
            expect.bool(direction == #increase).equal(true);
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "supports threshold target with min and max",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Threshold Test";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "metric:0";
          target = #threshold({ min = ?10.0; max = ?100.0 });
          targetDate = null;
        };

        ignore ObjectiveModel.addObjective(map, 0, 0, input);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        switch (o.target) {
          case (#threshold({ min; max })) {
            switch (min) {
              case (?m) { expect.bool(m == 10.0).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
            switch (max) {
              case (?m) { expect.bool(m == 100.0).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
          };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "supports boolean target",
      func() {
        let map = ObjectiveModel.emptyObjectivesMap();
        ObjectiveModel.initValueStreamObjectives(map, 0, 0);
        let input : ObjectiveModel.ObjectiveInput = {
          name = "Boolean Test";
          description = null;
          objectiveType = #target;
          metricIds = [0];
          computation = "metric:0";
          target = #boolean(true);
          targetDate = null;
        };

        ignore ObjectiveModel.addObjective(map, 0, 0, input);

        let o = unwrapObjective(ObjectiveModel.getObjective(map, 0, 0, 0));
        switch (o.target) {
          case (#boolean(b)) { expect.bool(b).equal(true) };
          case (_) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);
