import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { createBackendCanister, type _SERVICE } from "../../setup.ts";
import { expectErr, expectOk } from "../../helpers.ts";
import type {
  ObjectiveInput,
  ObjectiveTarget,
  ObjectiveDatapoint,
  ObjectiveDatapointComment,
  ValueStreamInput,
  MetricRegistrationInput,
} from "../../builds/open-org-backend.did.d.ts";

describe("Objectives API", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  const defaultWorkspaceId = 0n;
  let defaultValueStreamId: bigint;
  let defaultMetricId: bigint;

  const createValueStream = async (): Promise<bigint> => {
    const input: ValueStreamInput = {
      name: "Test Value Stream",
      problem: "Test problem",
      goal: "Test goal",
    };
    const result = await actor.createValueStream(defaultWorkspaceId, input);
    return expectOk(result).id;
  };

  const registerMetric = async (): Promise<bigint> => {
    const input: MetricRegistrationInput = {
      name: "Test Metric",
      description: "A test metric for objectives",
      unit: "count",
      retentionDays: 30n,
    };
    const result = await actor.registerMetric(input);
    return expectOk(result).id;
  };

  const defaultObjectiveInput = (): ObjectiveInput => ({
    name: "Test Objective",
    description: ["A test objective"],
    objectiveType: { target: null },
    metricIds: [defaultMetricId],
    computation: "avg(metrics)",
    target: { percentage: { target: 80.0 } },
    targetDate: [BigInt(Date.now()) * 1_000_000n + 86400_000_000_000n], // tomorrow
  });

  beforeEach(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
    actor = testEnv.actor;
    defaultValueStreamId = await createValueStream();
    defaultMetricId = await registerMetric();
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("addObjective", () => {
    it("should allow workspace admin to add an objective", async () => {
      const input = defaultObjectiveInput();
      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const obj = expectOk(result);

      expect(obj.id).toBe(0n);
      expect(obj.name).toBe("Test Objective");
      expect(obj.description).toEqual(["A test objective"]);
      expect(obj.metricIds).toEqual([defaultMetricId]);
      expect(obj.computation).toBe("avg(metrics)");
      expect(obj.target).toEqual({ percentage: { target: 80.0 } });
      expect(obj.status).toEqual({ active: null });
      expect(obj.current).toEqual([]);
      expect(obj.history).toEqual([]);
    });

    it("should reject non-admin from adding an objective", async () => {
      actor.setIdentity(generateRandomIdentity());

      const input = defaultObjectiveInput();
      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });

    it("should reject empty name", async () => {
      const input = defaultObjectiveInput();
      input.name = "";

      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      expect(expectErr(result)).toContain("name");
    });

    it("should reject empty computation", async () => {
      const input = defaultObjectiveInput();
      input.computation = "";

      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      expect(expectErr(result)).toContain("computation");
    });

    it("should increment objective IDs", async () => {
      const input1 = defaultObjectiveInput();
      input1.name = "Objective 1";

      const input2 = defaultObjectiveInput();
      input2.name = "Objective 2";

      const result1 = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input1,
      );
      const result2 = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input2,
      );

      expect(expectOk(result1).id).toBe(0n);
      expect(expectOk(result2).id).toBe(1n);
    });

    it("should support different target types", async () => {
      const targets: ObjectiveTarget[] = [
        { percentage: { target: 95.0 } },
        { count: { target: 100.0, direction: { increase: null } } },
        { count: { target: 50.0, direction: { decrease: null } } },
        { threshold: { min: [10.0], max: [100.0] } },
        { threshold: { min: [], max: [50.0] } },
        { boolean: true },
      ];

      for (let i = 0; i < targets.length; i++) {
        const input = defaultObjectiveInput();
        input.name = `Objective ${i}`;
        input.target = targets[i];

        const result = await actor.addObjective(
          defaultWorkspaceId,
          defaultValueStreamId,
          input,
        );
        const obj = expectOk(result);
        expect(obj.target).toEqual(targets[i]);
      }
    });

    it("should allow objective without description", async () => {
      const input = defaultObjectiveInput();
      input.description = [];

      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const obj = expectOk(result);
      expect(obj.description).toEqual([]);
    });

    it("should allow objective without target date", async () => {
      const input = defaultObjectiveInput();
      input.targetDate = [];

      const result = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const obj = expectOk(result);
      expect(obj.targetDate).toEqual([]);
    });
  });

  describe("getObjective", () => {
    it("should get an existing objective", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const addedObj = expectOk(addResult);

      const getResult = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        addedObj.id,
      );
      const obj = expectOk(getResult);

      expect(obj.id).toBe(addedObj.id);
      expect(obj.name).toBe("Test Objective");
    });

    it("should return error for non-existent objective", async () => {
      const result = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        999n,
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from getting objective", async () => {
      const input = defaultObjectiveInput();
      await actor.addObjective(defaultWorkspaceId, defaultValueStreamId, input);

      actor.setIdentity(generateRandomIdentity());
      const result = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        0n,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("listObjectives", () => {
    it("should list all objectives for a value stream", async () => {
      const input1 = defaultObjectiveInput();
      input1.name = "Objective 1";
      const input2 = defaultObjectiveInput();
      input2.name = "Objective 2";

      await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input1,
      );
      await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input2,
      );

      const result = await actor.listObjectives(
        defaultWorkspaceId,
        defaultValueStreamId,
      );
      const objs = expectOk(result);

      expect(objs.length).toBe(2);
      expect(objs.map((o) => o.name).sort()).toEqual([
        "Objective 1",
        "Objective 2",
      ]);
    });

    it("should return empty array for value stream with no objectives", async () => {
      // Create a new value stream without objectives
      const newVsId = await createValueStream();

      const result = await actor.listObjectives(defaultWorkspaceId, newVsId);
      const objs = expectOk(result);
      expect(objs).toEqual([]);
    });

    it("should reject non-admin from listing objectives", async () => {
      actor.setIdentity(generateRandomIdentity());

      const result = await actor.listObjectives(
        defaultWorkspaceId,
        defaultValueStreamId,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("updateObjective", () => {
    it("should update objective name", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const updateResult = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        ["Updated Name"], // newName
        [], // newDescription - no change
        [], // newObjectiveType - no change
        [], // newMetricIds - no change
        [], // newComputation - no change
        [], // newTarget - no change
        [], // newTargetDate - no change
        [], // newStatus - no change
      );
      const updatedObj = expectOk(updateResult);

      expect(updatedObj.name).toBe("Updated Name");
      expect(updatedObj.description).toEqual(["A test objective"]);
    });

    it("should update objective description", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const updateResult = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        [], // newName
        [["New description"]], // newDescription - set to new value
        [],
        [],
        [],
        [],
        [],
        [],
      );
      const updatedObj = expectOk(updateResult);

      expect(updatedObj.description).toEqual(["New description"]);
    });

    it("should clear optional description", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const updateResult = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        [],
        [[]], // newDescription - explicitly set to none
        [],
        [],
        [],
        [],
        [],
        [],
      );
      const updatedObj = expectOk(updateResult);

      expect(updatedObj.description).toEqual([]);
    });

    it("should update objective target", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const newTarget: ObjectiveTarget = {
        count: { target: 50.0, direction: { decrease: null } },
      };

      const updateResult = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        [],
        [],
        [],
        [],
        [],
        [newTarget], // newTarget
        [],
        [],
      );
      const updatedObj = expectOk(updateResult);

      expect(updatedObj.target).toEqual(newTarget);
    });

    it("should update objective status", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const updateResult = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        [],
        [],
        [],
        [],
        [],
        [],
        [],
        [{ paused: null }], // newStatus
      );
      const updatedObj = expectOk(updateResult);

      expect(updatedObj.status).toEqual({ paused: null });
    });

    it("should return error for non-existent objective", async () => {
      const result = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        999n,
        ["New Name"],
        [],
        [],
        [],
        [],
        [],
        [],
        [],
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from updating objective", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      actor.setIdentity(generateRandomIdentity());
      const result = await actor.updateObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        ["Updated Name"],
        [],
        [],
        [],
        [],
        [],
        [],
        [],
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("archiveObjective", () => {
    it("should archive an objective", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const archiveResult = await actor.archiveObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      expectOk(archiveResult);

      const getResult = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const obj = expectOk(getResult);

      expect(obj.status).toEqual({ archived: null });
    });

    it("should return error for non-existent objective", async () => {
      const result = await actor.archiveObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        999n,
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from archiving objective", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      actor.setIdentity(generateRandomIdentity());
      const result = await actor.archiveObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("recordObjectiveDatapoint", () => {
    it("should record a datapoint for an objective", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };

      const recordResult = await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );
      expectOk(recordResult);

      const getResult = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const obj = expectOk(getResult);

      expect(obj.current).toEqual([75.5]);
      expect(obj.history.length).toBe(1);
      expect(obj.history[0].value).toEqual([75.5]);
    });

    it("should record datapoint with warning", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [50.0],
        valueWarning: ["Below target threshold"],
        comments: [],
      };

      const recordResult = await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );
      expectOk(recordResult);

      const getResult = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const obj = expectOk(getResult);

      expect(obj.history[0].valueWarning).toEqual(["Below target threshold"]);
    });

    it("should record multiple datapoints", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const baseTime = BigInt(Date.now() * 1_000_000);

      for (let i = 0; i < 3; i++) {
        const datapoint: ObjectiveDatapoint = {
          timestamp: baseTime + BigInt(i * 1_000_000_000),
          value: [60.0 + i * 10],
          valueWarning: [],
          comments: [],
        };
        await actor.recordObjectiveDatapoint(
          defaultWorkspaceId,
          defaultValueStreamId,
          objId,
          datapoint,
        );
      }

      const getResult = await actor.getObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const obj = expectOk(getResult);

      expect(obj.current).toEqual([80.0]); // Last recorded value
      expect(obj.history.length).toBe(3);
    });

    it("should return error for non-existent objective", async () => {
      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };

      const result = await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        999n,
        datapoint,
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from recording datapoint", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      actor.setIdentity(generateRandomIdentity());

      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };

      const result = await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("getObjectiveHistory", () => {
    it("should get objective history as array", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      // Record some datapoints
      const baseTime = BigInt(Date.now() * 1_000_000);
      for (let i = 0; i < 3; i++) {
        const datapoint: ObjectiveDatapoint = {
          timestamp: baseTime + BigInt(i * 1_000_000_000),
          value: [60.0 + i * 10],
          valueWarning: [],
          comments: [],
        };
        await actor.recordObjectiveDatapoint(
          defaultWorkspaceId,
          defaultValueStreamId,
          objId,
          datapoint,
        );
      }

      const historyResult = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const history = expectOk(historyResult);

      expect(history.length).toBe(3);
      // History is stored in chronological order (appended to end)
      // Check values exist and stored in correct order
      const values = history.map((h) => h.value[0]);
      expect(values).toEqual([60.0, 70.0, 80.0]);
    });

    it("should return empty array for objective with no history", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const historyResult = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const history = expectOk(historyResult);

      expect(history).toEqual([]);
    });

    it("should return error for non-existent objective", async () => {
      const result = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        999n,
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from getting history", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      actor.setIdentity(generateRandomIdentity());
      const result = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("addObjectiveDatapointComment", () => {
    it("should add a comment to a history datapoint", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      // Record a datapoint
      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };
      await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );

      // Add comment to the first (index 0) history entry
      const comment: ObjectiveDatapointComment = {
        timestamp: BigInt(Date.now() * 1_000_000),
        author: { assistant: "Test AI" },
        message: "This value looks good!",
      };

      const commentResult = await actor.addObjectiveDatapointComment(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        0n, // history index
        comment,
      );
      expectOk(commentResult);

      const historyResult = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const history = expectOk(historyResult);

      expect(history[0].comments.length).toBe(1);
      expect(history[0].comments[0].message).toBe("This value looks good!");
      expect(history[0].comments[0].author).toEqual({ assistant: "Test AI" });
    });

    it("should support different author types", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };
      await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );

      const baseTime = BigInt(Date.now() * 1_000_000);

      // Add comment from task
      await actor.addObjectiveDatapointComment(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        0n,
        {
          timestamp: baseTime,
          author: { task: "daily-check" },
          message: "Automated check passed",
        },
      );

      const historyResult = await actor.getObjectiveHistory(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
      );
      const history = expectOk(historyResult);

      expect(history[0].comments[0].author).toEqual({ task: "daily-check" });
    });

    it("should return error for invalid history index", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      // Record one datapoint
      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };
      await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );

      const comment: ObjectiveDatapointComment = {
        timestamp: BigInt(Date.now() * 1_000_000),
        author: { assistant: "Test AI" },
        message: "This should fail",
      };

      // Try to add comment to index 5 (doesn't exist)
      const result = await actor.addObjectiveDatapointComment(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        5n,
        comment,
      );
      expect(expectErr(result)).toContain("not found");
    });

    it("should reject non-admin from adding comment", async () => {
      const input = defaultObjectiveInput();
      const addResult = await actor.addObjective(
        defaultWorkspaceId,
        defaultValueStreamId,
        input,
      );
      const objId = expectOk(addResult).id;

      const datapoint: ObjectiveDatapoint = {
        timestamp: BigInt(Date.now() * 1_000_000),
        value: [75.5],
        valueWarning: [],
        comments: [],
      };
      await actor.recordObjectiveDatapoint(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        datapoint,
      );

      actor.setIdentity(generateRandomIdentity());

      const comment: ObjectiveDatapointComment = {
        timestamp: BigInt(Date.now() * 1_000_000),
        author: { assistant: "Test AI" },
        message: "This should fail",
      };

      const result = await actor.addObjectiveDatapointComment(
        defaultWorkspaceId,
        defaultValueStreamId,
        objId,
        0n,
        comment,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("value stream deletion cleanup", () => {
    it("should delete objectives when value stream is deleted", async () => {
      const input = defaultObjectiveInput();
      await actor.addObjective(defaultWorkspaceId, defaultValueStreamId, input);

      // Verify objective exists
      const listResult = await actor.listObjectives(
        defaultWorkspaceId,
        defaultValueStreamId,
      );
      expect(expectOk(listResult).length).toBe(1);

      // Delete value stream
      await actor.deleteValueStream(defaultWorkspaceId, defaultValueStreamId);

      // Create a new value stream and verify no objectives leak
      const newVsId = await createValueStream();
      const newListResult = await actor.listObjectives(
        defaultWorkspaceId,
        newVsId,
      );
      expect(expectOk(newListResult)).toEqual([]);
    });
  });
});
