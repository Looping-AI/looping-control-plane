import { test; suite; expect } "mo:test";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import AuthMiddleware "../../../../src/open-org-backend/middleware/auth-middleware";

// ============================================
// Test Principals (all valid non-anonymous principals)
// ============================================

let owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let orgAdmin1 = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let orgAdmin2 = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
let workspaceAdmin1 = Principal.fromText("aaaaa-aa");
let workspaceAdmin2 = Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai");
let workspaceMember1 = Principal.fromText("renrk-eyaaa-aaaaa-aaada-cai");
let workspaceMember2 = Principal.fromText("rno2w-sqaaa-aaaaa-aaacq-cai");
let regularUser = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
let anonymous = Principal.fromBlob("\04");

// ============================================
// Test Context Setup
// ============================================

let baseContext : AuthMiddleware.AuthContext = {
  caller = owner;
  workspaceId = null;
  orgOwner = owner;
  orgAdmins = [orgAdmin1, orgAdmin2];
  workspaceAdmins = Map.fromArray<Nat, [Principal]>(
    [
      (0, [workspaceAdmin1]),
      (1, [workspaceAdmin2]),
    ],
    Nat.compare,
  );
  workspaceMembers = Map.fromArray<Nat, [Principal]>(
    [
      (0, [workspaceMember1]),
      (1, [workspaceMember2]),
    ],
    Nat.compare,
  );
};

func createContext(caller : Principal, workspaceId : ?Nat) : AuthMiddleware.AuthContext {
  {
    baseContext with
    caller;
    workspaceId;
  };
};

// ============================================
// Helper Functions
// ============================================

func resultToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

// ============================================
// Universal Anonymous Check
// ============================================

suite(
  "Anonymous caller rejection",
  func() {
    test(
      "should reject anonymous caller regardless of role",
      func() {
        let ctx = createContext(anonymous, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Please login before calling this function."));
      },
    );

    test(
      "should reject anonymous even with multiple auth steps",
      func() {
        let ctx = createContext(anonymous, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner, #IsOrgAdmin, #IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Please login before calling this function."));
      },
    );
  },
);

// ============================================
// IsOrgOwner Tests
// ============================================

suite(
  "IsOrgOwner authorization",
  func() {
    test(
      "should allow org owner",
      func() {
        let ctx = createContext(owner, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject non-owner",
      func() {
        let ctx = createContext(orgAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org owner can perform this action."));
      },
    );

    test(
      "should reject regular user",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org owner can perform this action."));
      },
    );
  },
);

// ============================================
// IsOrgAdmin Tests
// ============================================

suite(
  "IsOrgAdmin authorization",
  func() {
    test(
      "should allow org admin",
      func() {
        let ctx = createContext(orgAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow different org admin",
      func() {
        let ctx = createContext(orgAdmin2, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject non-admin",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org admins can perform this action."));
      },
    );

    test(
      "should reject workspace admin who is not org admin",
      func() {
        let ctx = createContext(workspaceAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org admins can perform this action."));
      },
    );
  },
);

// ============================================
// IsWorkspaceAdmin Tests - Specific Workspace
// ============================================

suite(
  "IsWorkspaceAdmin authorization - specific workspace",
  func() {
    test(
      "should allow workspace admin for their workspace",
      func() {
        let ctx = createContext(workspaceAdmin1, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow different workspace admin for their workspace",
      func() {
        let ctx = createContext(workspaceAdmin2, ?1);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject workspace admin for wrong workspace",
      func() {
        let ctx = createContext(workspaceAdmin1, ?1);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );

    test(
      "should reject non-admin for workspace",
      func() {
        let ctx = createContext(regularUser, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );

    test(
      "should reject for non-existent workspace",
      func() {
        let ctx = createContext(workspaceAdmin1, ?999);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Workspace not found."));
      },
    );
  },
);

// ============================================
// AnyWorkspaceAdmin Tests
// ============================================

suite(
  "AnyWorkspaceAdmin authorization",
  func() {
    test(
      "should allow workspace admin from workspace 0",
      func() {
        let ctx = createContext(workspaceAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#AnyWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow workspace admin from workspace 1",
      func() {
        let ctx = createContext(workspaceAdmin2, null);
        let result = AuthMiddleware.authorize(ctx, [#AnyWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject user who is not admin of any workspace",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(ctx, [#AnyWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );

    test(
      "should reject workspace member who is not admin",
      func() {
        let ctx = createContext(workspaceMember1, null);
        let result = AuthMiddleware.authorize(ctx, [#AnyWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );
  },
);

// ============================================
// IsWorkspaceAdmin Tests - Requires workspaceId
// ============================================

suite(
  "IsWorkspaceAdmin requires workspaceId",
  func() {
    test(
      "should reject when workspaceId is null",
      func() {
        let ctx = createContext(workspaceAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Workspace ID is required."));
      },
    );
  },
);

// ============================================
// IsWorkspaceMember Tests - Specific Workspace
// ============================================

suite(
  "IsWorkspaceMember authorization - specific workspace",
  func() {
    test(
      "should allow workspace member for their workspace",
      func() {
        let ctx = createContext(workspaceMember1, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow different workspace member for their workspace",
      func() {
        let ctx = createContext(workspaceMember2, ?1);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject workspace member for wrong workspace",
      func() {
        let ctx = createContext(workspaceMember1, ?1);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace members can perform this action."));
      },
    );

    test(
      "should reject non-member for workspace",
      func() {
        let ctx = createContext(regularUser, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace members can perform this action."));
      },
    );

    test(
      "should reject when workspace ID is required but not provided",
      func() {
        let ctx = createContext(workspaceMember1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Workspace ID is required."));
      },
    );

    test(
      "should reject for non-existent workspace",
      func() {
        let ctx = createContext(workspaceMember1, ?999);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Workspace not found."));
      },
    );
  },
);

// ============================================
// Multiple Steps Tests (OR Logic)
// ============================================

suite(
  "Multiple authorization steps (OR logic)",
  func() {
    test(
      "should allow org owner when checking owner OR admin",
      func() {
        let ctx = createContext(owner, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner, #IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow org admin when checking owner OR admin",
      func() {
        let ctx = createContext(orgAdmin1, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner, #IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow workspace admin when checking owner OR admin OR workspace admin",
      func() {
        let ctx = createContext(workspaceAdmin1, null);
        let result = AuthMiddleware.authorize(
          ctx,
          [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin],
        );
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should reject when none of the OR conditions match",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(
          ctx,
          [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin],
        );
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Only org owner, org admins, workspace admins can perform this action.")
        );
      },
    );

    test(
      "should allow workspace member when checking admin OR member",
      func() {
        let ctx = createContext(workspaceMember1, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin, #IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "should allow workspace admin when checking admin OR member",
      func() {
        let ctx = createContext(workspaceAdmin1, ?0);
        let result = AuthMiddleware.authorize(ctx, [#IsWorkspaceAdmin, #IsWorkspaceMember]);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );
  },
);

// ============================================
// Error Message Formatting Tests
// ============================================

suite(
  "Error message formatting",
  func() {
    test(
      "should format single role error",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org owner can perform this action."));
      },
    );

    test(
      "should consolidate two role errors",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(ctx, [#IsOrgOwner, #IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org owner, org admins can perform this action."));
      },
    );

    test(
      "should consolidate three role errors",
      func() {
        let ctx = createContext(regularUser, null);
        let result = AuthMiddleware.authorize(
          ctx,
          [#IsOrgOwner, #IsOrgAdmin, #AnyWorkspaceAdmin],
        );
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Only org owner, org admins, workspace admins can perform this action.")
        );
      },
    );

    test(
      "should include non-role errors with role errors",
      func() {
        let ctx = createContext(regularUser, ?0); // Use existing workspace 0
        let result = AuthMiddleware.authorize(ctx, [#IsOrgAdmin, #IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Only org admins, workspace admins can perform this action.")
        );
      },
    );
  },
);

// ============================================
// Edge Cases
// ============================================

suite(
  "Edge cases",
  func() {
    test(
      "should handle empty workspaceAdmins map",
      func() {
        let emptyContext : AuthMiddleware.AuthContext = {
          baseContext with
          caller = workspaceAdmin1;
          workspaceId = null;
          workspaceAdmins = Map.empty<Nat, [Principal]>();
        };
        let result = AuthMiddleware.authorize(emptyContext, [#AnyWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );

    test(
      "should handle empty orgAdmins array",
      func() {
        let emptyAdminContext : AuthMiddleware.AuthContext = {
          baseContext with
          caller = orgAdmin1;
          orgAdmins = [];
        };
        let result = AuthMiddleware.authorize(emptyAdminContext, [#IsOrgAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only org admins can perform this action."));
      },
    );

    test(
      "should handle workspace with empty admins array",
      func() {
        let emptyWorkspaceAdmins = Map.fromArray<Nat, [Principal]>([(0, [])], Nat.compare);
        let emptyWsContext : AuthMiddleware.AuthContext = {
          baseContext with
          caller = workspaceAdmin1;
          workspaceId = ?0;
          workspaceAdmins = emptyWorkspaceAdmins;
        };
        let result = AuthMiddleware.authorize(emptyWsContext, [#IsWorkspaceAdmin]);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(#err("Only workspace admins can perform this action."));
      },
    );
  },
);
