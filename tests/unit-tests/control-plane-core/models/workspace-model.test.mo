import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import WorkspaceModel "../../../../src/control-plane-core/models/workspace-model";

// ============================================
// Helpers
// ============================================

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

func resolutionEqual(
  r1 : WorkspaceModel.ChannelResolution,
  r2 : WorkspaceModel.ChannelResolution,
) : Bool { r1 == r2 };

// ============================================
// Suite: createWorkspace
// ============================================

suite(
  "WorkspaceModel - createWorkspace",
  func() {
    test(
      "rejects empty name",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.createWorkspace(state, "");
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("Workspace name cannot be empty.")
        );
      },
    );

    test(
      "returns id 1 for first explicit workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.createWorkspace(state, "Engineering");
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(1));
      },
    );

    test(
      "returns incrementing ids for successive workspaces",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        let result = WorkspaceModel.createWorkspace(state, "Marketing");
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(#ok(2));
      },
    );

    test(
      "rejects duplicate workspace name",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        let result = WorkspaceModel.createWorkspace(state, "Engineering");
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("A workspace with this name already exists.")
        );
      },
    );

    test(
      "rejects name that duplicates the Default workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.createWorkspace(state, "Default");
        expect.result<Nat, Text>(result, resultNatToText, resultNatEqual).equal(
          #err("A workspace with this name already exists.")
        );
      },
    );

    test(
      "new workspace has null channel anchors",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.option<Text>(ws.adminChannelId, func t { t }, func(a, b) { a == b }).isNull();
            expect.option<Text>(ws.memberChannelId, func t { t }, func(a, b) { a == b }).isNull();
          };
        };
      },
    );
  },
);

// ============================================
// Suite: getWorkspace
// ============================================

suite(
  "WorkspaceModel - getWorkspace",
  func() {
    test(
      "returns the pre-seeded Default workspace at id 0",
      func() {
        let state = WorkspaceModel.emptyState();
        switch (WorkspaceModel.getWorkspace(state, 0)) {
          case (null) { assert false };
          case (?ws) {
            expect.text(ws.name).equal("Default");
            expect.nat(ws.id).equal(0);
          };
        };
      },
    );

    test(
      "returns workspace after creation",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.text(ws.name).equal("Engineering");
          };
        };
      },
    );

    test(
      "returns null for non-existent id",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.getWorkspace(state, 999);
        expect.option<WorkspaceModel.WorkspaceRecord>(
          result,
          func ws { ws.name },
          func(a, b) { a.id == b.id },
        ).isNull();
      },
    );
  },
);

// ============================================
// Suite: listWorkspaces
// ============================================

suite(
  "WorkspaceModel - listWorkspaces",
  func() {
    test(
      "fresh state contains only the Default workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        let list = WorkspaceModel.listWorkspaces(state);
        expect.nat(list.size()).equal(1);
      },
    );

    test(
      "reflects newly created workspaces",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        let list = WorkspaceModel.listWorkspaces(state);
        expect.nat(list.size()).equal(3); // Default + 2
      },
    );
  },
);

// ============================================
// Suite: setAdminChannel
// ============================================

suite(
  "WorkspaceModel - setAdminChannel",
  func() {
    test(
      "rejects unknown workspace id",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.setAdminChannel(state, 99, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "sets admin channel successfully",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        let result = WorkspaceModel.setAdminChannel(state, 1, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.option<Text>(ws.adminChannelId, func t { t }, func(a, b) { a == b }).equal(?"C001");
          };
        };
      },
    );

    test(
      "re-assigning the same channel id to the same admin slot is allowed",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        let result = WorkspaceModel.setAdminChannel(state, 1, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();
      },
    );

    test(
      "rejects channel already used as admin anchor in another workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        let result = WorkspaceModel.setAdminChannel(state, 2, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as an admin anchor in another workspace.")
        );
      },
    );

    test(
      "rejects channel already used as member anchor in another workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C001");
        let result = WorkspaceModel.setAdminChannel(state, 2, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as a member anchor in another workspace.")
        );
      },
    );

    test(
      "rejects channel already used as the member anchor of the same workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C001");
        let result = WorkspaceModel.setAdminChannel(state, 1, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as the member anchor of this workspace.")
        );
      },
    );

    test(
      "does not affect member channel when setting admin channel",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.option<Text>(ws.memberChannelId, func t { t }, func(a, b) { a == b }).equal(?"C002");
          };
        };
      },
    );
  },
);

// ============================================
// Suite: setMemberChannel
// ============================================

suite(
  "WorkspaceModel - setMemberChannel",
  func() {
    test(
      "rejects unknown workspace id",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.setMemberChannel(state, 99, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Workspace not found.")
        );
      },
    );

    test(
      "sets member channel successfully",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        let result = WorkspaceModel.setMemberChannel(state, 1, "C002");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.option<Text>(ws.memberChannelId, func t { t }, func(a, b) { a == b }).equal(?"C002");
          };
        };
      },
    );

    test(
      "re-assigning the same channel id to the same member slot is allowed",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        let result = WorkspaceModel.setMemberChannel(state, 1, "C002");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).isOk();
      },
    );

    test(
      "rejects channel already used as member anchor in another workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        let result = WorkspaceModel.setMemberChannel(state, 2, "C002");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as a member anchor in another workspace.")
        );
      },
    );

    test(
      "rejects channel already used as admin anchor in another workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        let result = WorkspaceModel.setMemberChannel(state, 2, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as an admin anchor in another workspace.")
        );
      },
    );

    test(
      "rejects channel already used as the admin anchor of the same workspace",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        let result = WorkspaceModel.setMemberChannel(state, 1, "C001");
        expect.result<(), Text>(result, resultUnitToText, resultUnitEqual).equal(
          #err("Channel is already used as the admin anchor of this workspace.")
        );
      },
    );

    test(
      "does not affect admin channel when setting member channel",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        switch (WorkspaceModel.getWorkspace(state, 1)) {
          case (null) { assert false };
          case (?ws) {
            expect.option<Text>(ws.adminChannelId, func t { t }, func(a, b) { a == b }).equal(?"C001");
          };
        };
      },
    );
  },
);

// ============================================
// Suite: resolveWorkspaceByChannel
// ============================================

suite(
  "WorkspaceModel - resolveWorkspaceByChannel",
  func() {
    test(
      "returns #none for unknown channel",
      func() {
        let state = WorkspaceModel.emptyState();
        let result = WorkspaceModel.resolveWorkspaceByChannel(state, "C_UNKNOWN");
        expect.bool(resolutionEqual(result, #none)).isTrue();
      },
    );

    test(
      "returns #adminChannel with correct workspace id",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        let result = WorkspaceModel.resolveWorkspaceByChannel(state, "C001");
        expect.bool(resolutionEqual(result, #adminChannel(1))).isTrue();
      },
    );

    test(
      "returns #memberChannel with correct workspace id",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        let result = WorkspaceModel.resolveWorkspaceByChannel(state, "C002");
        expect.bool(resolutionEqual(result, #memberChannel(1))).isTrue();
      },
    );

    test(
      "resolves admin and member channels of the same workspace independently",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        ignore WorkspaceModel.setMemberChannel(state, 1, "C002");
        expect.bool(resolutionEqual(WorkspaceModel.resolveWorkspaceByChannel(state, "C001"), #adminChannel(1))).isTrue();
        expect.bool(resolutionEqual(WorkspaceModel.resolveWorkspaceByChannel(state, "C002"), #memberChannel(1))).isTrue();
      },
    );

    test(
      "resolves channels across multiple workspaces correctly",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        ignore WorkspaceModel.createWorkspace(state, "Marketing");
        ignore WorkspaceModel.setAdminChannel(state, 1, "C001");
        ignore WorkspaceModel.setMemberChannel(state, 2, "C010");
        expect.bool(resolutionEqual(WorkspaceModel.resolveWorkspaceByChannel(state, "C001"), #adminChannel(1))).isTrue();
        expect.bool(resolutionEqual(WorkspaceModel.resolveWorkspaceByChannel(state, "C010"), #memberChannel(2))).isTrue();
        expect.bool(resolutionEqual(WorkspaceModel.resolveWorkspaceByChannel(state, "C_NONE"), #none)).isTrue();
      },
    );

    test(
      "returns #none for workspace with no anchors set",
      func() {
        let state = WorkspaceModel.emptyState();
        ignore WorkspaceModel.createWorkspace(state, "Engineering");
        let result = WorkspaceModel.resolveWorkspaceByChannel(state, "C001");
        expect.bool(resolutionEqual(result, #none)).isTrue();
      },
    );
  },
);
