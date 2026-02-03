import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { createTestEnvironment, type _SERVICE } from "../../setup.ts";
import { expectErr, expectOk } from "../../helpers.ts";
import type {
  ValueStreamInput,
  ValueStreamStatus,
} from "../../builds/open-org-backend.did.d.ts";

describe("Value Streams API", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  const defaultWorkspaceId = 0n;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("createValueStream", () => {
    it("should allow workspace admin to create a value stream", async () => {
      const input: ValueStreamInput = {
        name: "Customer Onboarding",
        problem: "Customers take too long to get started",
        goal: "Reduce onboarding time to under 5 minutes",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      const vs = expectOk(result);

      expect(vs.id).toBe(0n);
      expect(vs.name).toBe("Customer Onboarding");
      expect(vs.problem).toBe("Customers take too long to get started");
      expect(vs.goal).toBe("Reduce onboarding time to under 5 minutes");
      expect(vs.workspaceId).toBe(defaultWorkspaceId);
      expect(vs.status).toEqual({ draft: null });
    });

    it("should reject non-admin from creating a value stream", async () => {
      actor.setIdentity(generateRandomIdentity());

      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Some problem",
        goal: "Some goal",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      expect(expectErr(result)).toContain("workspace admins");
    });

    it("should reject empty name", async () => {
      const input: ValueStreamInput = {
        name: "",
        problem: "Some problem",
        goal: "Some goal",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      expect(expectErr(result)).toBe("Value stream name cannot be empty.");
    });

    it("should reject empty problem", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "",
        goal: "Some goal",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      expect(expectErr(result)).toBe("Value stream problem cannot be empty.");
    });

    it("should reject empty goal", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Some problem",
        goal: "",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      expect(expectErr(result)).toBe("Value stream goal cannot be empty.");
    });

    it("should increment value stream IDs", async () => {
      const input1: ValueStreamInput = {
        name: "Stream 1",
        problem: "Problem 1",
        goal: "Goal 1",
      };

      const input2: ValueStreamInput = {
        name: "Stream 2",
        problem: "Problem 2",
        goal: "Goal 2",
      };

      const result1 = await actor.createValueStream(defaultWorkspaceId, input1);
      const result2 = await actor.createValueStream(defaultWorkspaceId, input2);

      expect(expectOk(result1).id).toBe(0n);
      expect(expectOk(result2).id).toBe(1n);
    });
  });

  describe("getValueStream", () => {
    it("should return a created value stream", async () => {
      const input: ValueStreamInput = {
        name: "Customer Onboarding",
        problem: "Slow onboarding",
        goal: "Fast onboarding",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      const getResult = await actor.getValueStream(
        defaultWorkspaceId,
        created.id,
      );
      const vs = expectOk(getResult);

      expect(vs.id).toBe(created.id);
      expect(vs.name).toBe("Customer Onboarding");
    });

    it("should return error for non-existent value stream", async () => {
      const result = await actor.getValueStream(defaultWorkspaceId, 999n);
      expect(expectErr(result)).toBe("Value stream not found.");
    });

    it("should reject non-admin from getting a value stream", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      actor.setIdentity(generateRandomIdentity());

      const result = await actor.getValueStream(defaultWorkspaceId, created.id);
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("listValueStreams", () => {
    it("should return empty array when no value streams exist", async () => {
      const result = await actor.listValueStreams(defaultWorkspaceId);
      expect(expectOk(result)).toEqual([]);
    });

    it("should return all value streams in workspace", async () => {
      const input1: ValueStreamInput = {
        name: "Stream A",
        problem: "Problem A",
        goal: "Goal A",
      };

      const input2: ValueStreamInput = {
        name: "Stream B",
        problem: "Problem B",
        goal: "Goal B",
      };

      await actor.createValueStream(defaultWorkspaceId, input1);
      await actor.createValueStream(defaultWorkspaceId, input2);

      const result = await actor.listValueStreams(defaultWorkspaceId);
      const streams = expectOk(result);

      expect(streams.length).toBe(2);
      expect(streams.map((s) => s.name).sort()).toEqual([
        "Stream A",
        "Stream B",
      ]);
    });

    it("should reject non-admin from listing value streams", async () => {
      actor.setIdentity(generateRandomIdentity());

      const result = await actor.listValueStreams(defaultWorkspaceId);
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("updateValueStream", () => {
    it("should update value stream name", async () => {
      const input: ValueStreamInput = {
        name: "Original Name",
        problem: "Original Problem",
        goal: "Original Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        ["New Name"], // newName
        [], // newProblem
        [], // newGoal
        [], // newStatus
      );
      const updated = expectOk(updateResult);

      expect(updated.name).toBe("New Name");
      expect(updated.problem).toBe("Original Problem");
      expect(updated.goal).toBe("Original Goal");
    });

    it("should update value stream problem", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Original Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [], // newName
        ["New Problem"], // newProblem
        [], // newGoal
        [], // newStatus
      );
      const updated = expectOk(updateResult);

      expect(updated.problem).toBe("New Problem");
    });

    it("should update value stream goal", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Original Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [], // newName
        [], // newProblem
        ["New Goal"], // newGoal
        [], // newStatus
      );
      const updated = expectOk(updateResult);

      expect(updated.goal).toBe("New Goal");
    });

    it("should update value stream status", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);
      expect(created.status).toEqual({ draft: null });

      const newStatus: ValueStreamStatus = { active: null };
      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [], // newName
        [], // newProblem
        [], // newGoal
        [newStatus], // newStatus
      );
      const updated = expectOk(updateResult);

      expect(updated.status).toEqual({ active: null });
    });

    it("should update multiple fields at once", async () => {
      const input: ValueStreamInput = {
        name: "Original",
        problem: "Original Problem",
        goal: "Original Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      const newStatus: ValueStreamStatus = { active: null };
      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        ["Updated Name"],
        ["Updated Problem"],
        ["Updated Goal"],
        [newStatus],
      );
      const updated = expectOk(updateResult);

      expect(updated.name).toBe("Updated Name");
      expect(updated.problem).toBe("Updated Problem");
      expect(updated.goal).toBe("Updated Goal");
      expect(updated.status).toEqual({ active: null });
    });

    it("should return error for non-existent value stream", async () => {
      const result = await actor.updateValueStream(
        defaultWorkspaceId,
        999n,
        ["New Name"],
        [],
        [],
        [],
      );
      expect(expectErr(result)).toBe("Value stream not found.");
    });

    it("should reject non-admin from updating", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      actor.setIdentity(generateRandomIdentity());

      const result = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [""],
        [],
        [],
        [],
      );
      expect(expectErr(result)).toContain("workspace admins");
    });

    it("should update updatedAt timestamp", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);
      const originalUpdatedAt = created.updatedAt;

      // Wait a small amount of time
      await pic.advanceTime(1000);
      await pic.tick();

      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        ["New Name"],
        [],
        [],
        [],
      );
      const updated = expectOk(updateResult);

      expect(updated.updatedAt).toBeGreaterThan(originalUpdatedAt);
    });
  });

  describe("deleteValueStream", () => {
    it("should delete a value stream", async () => {
      const input: ValueStreamInput = {
        name: "Stream to delete",
        problem: "Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      // Verify it exists
      const getResult1 = await actor.getValueStream(
        defaultWorkspaceId,
        created.id,
      );
      expectOk(getResult1);

      // Delete
      const deleteResult = await actor.deleteValueStream(
        defaultWorkspaceId,
        created.id,
      );
      expectOk(deleteResult);

      // Verify it no longer exists
      const getResult2 = await actor.getValueStream(
        defaultWorkspaceId,
        created.id,
      );
      expect(expectErr(getResult2)).toBe("Value stream not found.");
    });

    it("should return error for non-existent value stream", async () => {
      const result = await actor.deleteValueStream(defaultWorkspaceId, 999n);
      expect(expectErr(result)).toBe("Value stream not found.");
    });

    it("should reject non-admin from deleting", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);

      actor.setIdentity(generateRandomIdentity());

      const result = await actor.deleteValueStream(
        defaultWorkspaceId,
        created.id,
      );
      expect(expectErr(result)).toContain("workspace admins");
    });
  });

  describe("status transitions", () => {
    it("should transition through all status values", async () => {
      const input: ValueStreamInput = {
        name: "Stream",
        problem: "Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const created = expectOk(createResult);
      expect(created.status).toEqual({ draft: null });

      // Draft -> Active
      const activeResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [],
        [],
        [],
        [{ active: null }],
      );
      expect(expectOk(activeResult).status).toEqual({ active: null });

      // Active -> Paused
      const pausedResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [],
        [],
        [],
        [{ paused: null }],
      );
      expect(expectOk(pausedResult).status).toEqual({ paused: null });

      // Paused -> Archived
      const archivedResult = await actor.updateValueStream(
        defaultWorkspaceId,
        created.id,
        [],
        [],
        [],
        [{ archived: null }],
      );
      expect(expectOk(archivedResult).status).toEqual({ archived: null });
    });
  });

  describe("org admin isolation", () => {
    it("should NOT allow org admin (without workspace admin role) to create value streams", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());

      actor.setIdentity(adminIdentity);

      const input: ValueStreamInput = {
        name: "Admin Created Stream",
        problem: "Problem",
        goal: "Goal",
      };

      const result = await actor.createValueStream(defaultWorkspaceId, input);
      expect(expectErr(result)).toContain("workspace admins");
    });

    it("should NOT allow org admin (without workspace admin role) to access value stream endpoints", async () => {
      // Create a value stream as owner (who is also workspace admin)
      const input: ValueStreamInput = {
        name: "Owner Created",
        problem: "Problem",
        goal: "Goal",
      };
      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const vs = expectOk(createResult);

      // Add org admin (but NOT as workspace admin)
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());
      actor.setIdentity(adminIdentity);

      // Org admin should NOT be able to access workspace-scoped value streams
      const getResult = await actor.getValueStream(defaultWorkspaceId, vs.id);
      expect(expectErr(getResult)).toContain("workspace admins");

      const listResult = await actor.listValueStreams(defaultWorkspaceId);
      expect(expectErr(listResult)).toContain("workspace admins");
    });
  });

  describe("workspace admin access", () => {
    it("should allow workspace admin to manage value streams", async () => {
      // Add a workspace admin (not org admin)
      const workspaceAdminIdentity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(
        defaultWorkspaceId,
        workspaceAdminIdentity.getPrincipal(),
      );

      actor.setIdentity(workspaceAdminIdentity);

      // Workspace admin should be able to create
      const input: ValueStreamInput = {
        name: "Workspace Admin Stream",
        problem: "Problem",
        goal: "Goal",
      };

      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const vs = expectOk(createResult);
      expect(vs.name).toBe("Workspace Admin Stream");

      // And list
      const listResult = await actor.listValueStreams(defaultWorkspaceId);
      expect(expectOk(listResult).length).toBe(1);

      // And update
      const updateResult = await actor.updateValueStream(
        defaultWorkspaceId,
        vs.id,
        ["Updated by WS Admin"],
        [],
        [],
        [],
      );
      expect(expectOk(updateResult).name).toBe("Updated by WS Admin");

      // And delete
      const deleteResult = await actor.deleteValueStream(
        defaultWorkspaceId,
        vs.id,
      );
      expectOk(deleteResult);
    });
  });

  describe("setValueStreamPlan", () => {
    it("should allow workspace admin to set a plan", async () => {
      // Create a value stream
      const input: ValueStreamInput = {
        name: "Growth Strategy",
        problem: "Low customer acquisition",
        goal: "Increase signups by 50%",
      };
      const createResult = await actor.createValueStream(
        defaultWorkspaceId,
        input,
      );
      const vs = expectOk(createResult);

      // Set a plan
      const planInput = {
        summary: "Focus on content marketing and referrals",
        currentState: "100 signups/month from direct traffic",
        targetState: "150 signups/month from multiple channels",
        steps: "1. Create blog\n2. Launch referral program\n3. Track metrics",
        risks: "Content may not rank - mitigation: paid ads backup",
        resources: "Content writer, referral software, $500/month budget",
      };

      const result = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "Initial plan",
      );

      const updated = expectOk(result);
      expect(updated.plan.length).toBe(1);
      const plan = updated.plan[0];
      if (!plan) throw new Error("Plan should exist");
      expect(plan.summary).toBe("Focus on content marketing and referrals");
      expect(plan.currentState).toBe("100 signups/month from direct traffic");
      expect(plan.targetState).toBe("150 signups/month from multiple channels");
      expect(plan.steps).toBe(
        "1. Create blog\n2. Launch referral program\n3. Track metrics",
      );
      expect(plan.risks).toBe(
        "Content may not rank - mitigation: paid ads backup",
      );
      expect(plan.resources).toBe(
        "Content writer, referral software, $500/month budget",
      );

      // Check plan history
      expect(updated.planHistory.length).toBe(1);
      expect(updated.planHistory[0].diff).toBe("Initial plan");
    });

    it("should update existing plan and record in history", async () => {
      // Create value stream and set initial plan
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const vs = expectOk(
        await actor.createValueStream(defaultWorkspaceId, input),
      );

      const planInput1 = {
        summary: "Original approach",
        currentState: "Starting point",
        targetState: "End goal",
        steps: "Step 1",
        risks: "Risk A",
        resources: "Resource X",
      };

      await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput1,
        "First plan",
      );

      // Update the plan
      const planInput2 = {
        summary: "Revised approach after learning",
        currentState: "New starting point",
        targetState: "Adjusted end goal",
        steps: "Step 1\nStep 2",
        risks: "Risk A\nRisk B",
        resources: "Resource X\nResource Y",
      };

      const result = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput2,
        "Updated after market research",
      );

      const updated = expectOk(result);
      expect(updated.plan.length).toBe(1);
      const updatedPlan = updated.plan[0];
      if (!updatedPlan) throw new Error("Plan should exist");
      expect(updatedPlan.summary).toBe("Revised approach after learning");

      // Check history has both entries
      expect(updated.planHistory.length).toBe(2);
      expect(updated.planHistory[0].diff).toBe("First plan");
      expect(updated.planHistory[1].diff).toBe("Updated after market research");
    });

    it("should preserve createdAt when updating plan", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const vs = expectOk(
        await actor.createValueStream(defaultWorkspaceId, input),
      );

      const planInput = {
        summary: "Test",
        currentState: "Current",
        targetState: "Target",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      };

      // Set initial plan
      const result1 = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "First",
      );
      const firstPlan = expectOk(result1).plan[0];
      if (!firstPlan) throw new Error("First plan should exist");
      const initialCreatedAt = firstPlan.createdAt;

      // Update plan
      const result2 = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "Second",
      );
      const secondPlan = expectOk(result2).plan[0];
      if (!secondPlan) throw new Error("Second plan should exist");

      // createdAt should be preserved
      expect(secondPlan.createdAt).toBe(initialCreatedAt);
      // updatedAt should be different (or equal if same nanosecond)
      expect(secondPlan.updatedAt >= secondPlan.createdAt).toBe(true);
    });

    it("should allow clearing plan with empty strings", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const vs = expectOk(
        await actor.createValueStream(defaultWorkspaceId, input),
      );

      // Set initial plan
      const planInput = {
        summary: "Initial summary",
        currentState: "Current",
        targetState: "Target",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      };
      await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "Initial",
      );

      // Clear with empty strings
      const emptyPlan = {
        summary: "",
        currentState: "",
        targetState: "",
        steps: "",
        risks: "",
        resources: "",
      };
      const result = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        emptyPlan,
        "Cleared plan",
      );

      const updated = expectOk(result);
      expect(updated.plan.length).toBe(1);
      const clearedPlan = updated.plan[0];
      if (!clearedPlan) throw new Error("Cleared plan should exist");
      expect(clearedPlan.summary).toBe("");
      expect(updated.planHistory.length).toBe(2);
    });

    it("should reject non-admin from setting plan", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const vs = expectOk(
        await actor.createValueStream(defaultWorkspaceId, input),
      );

      actor.setIdentity(generateRandomIdentity());

      const planInput = {
        summary: "Unauthorized plan",
        currentState: "Current",
        targetState: "Target",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      };

      const result = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "Attempt",
      );

      expect(expectErr(result)).toContain("workspace admins");
    });

    it("should return error for non-existent value stream", async () => {
      const planInput = {
        summary: "Test",
        currentState: "Current",
        targetState: "Target",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      };

      const result = await actor.setValueStreamPlan(
        defaultWorkspaceId,
        999n,
        planInput,
        "Test",
      );

      expect(expectErr(result)).toBe("Value stream not found.");
    });

    it("should be reflected in getValueStream", async () => {
      const input: ValueStreamInput = {
        name: "Test Stream",
        problem: "Problem",
        goal: "Goal",
      };
      const vs = expectOk(
        await actor.createValueStream(defaultWorkspaceId, input),
      );

      const planInput = {
        summary: "Test plan",
        currentState: "Current",
        targetState: "Target",
        steps: "Steps",
        risks: "Risks",
        resources: "Resources",
      };

      await actor.setValueStreamPlan(
        defaultWorkspaceId,
        vs.id,
        planInput,
        "Set via API",
      );

      // Retrieve and verify
      const getResult = await actor.getValueStream(defaultWorkspaceId, vs.id);
      const retrieved = expectOk(getResult);

      expect(retrieved.plan.length).toBe(1);
      const retrievedPlan = retrieved.plan[0];
      if (!retrievedPlan) throw new Error("Retrieved plan should exist");
      expect(retrievedPlan.summary).toBe("Test plan");
      expect(retrieved.planHistory.length).toBe(1);
      expect(retrieved.planHistory[0].diff).toBe("Set via API");
    });
  });
});
