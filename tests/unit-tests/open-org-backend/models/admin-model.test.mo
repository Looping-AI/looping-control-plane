import { test; suite; expect } "mo:test";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import AdminModel "../../../../src/open-org-backend/models/admin-model";

// Helper functions for Result comparison
func resultToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

// Test principals
let testPrincipal1 = Principal.fromText("aaaaa-aa");
let testPrincipal2 = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let anonymousPrincipal = Principal.fromText("2vxsx-fae"); // Anonymous principal

suite(
  "AdminModel - validateNewAdmin",
  func() {
    test(
      "accepts valid new admin",
      func() {
        let admins : [Principal] = [];
        let result = AdminModel.validateNewAdmin(testPrincipal1, admins);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "rejects anonymous principal",
      func() {
        let admins : [Principal] = [];
        let result = AdminModel.validateNewAdmin(Principal.fromText("2vxsx-fae"), admins);
        // The anonymous principal "2vxsx-fae" should be rejected
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Anonymous users cannot be admins.")
        );
      },
    );

    test(
      "rejects principal already in admin list",
      func() {
        let admins : [Principal] = [testPrincipal1];
        let result = AdminModel.validateNewAdmin(testPrincipal1, admins);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Principal is already an admin.")
        );
      },
    );

    test(
      "accepts principal not in existing admin list",
      func() {
        let admins : [Principal] = [testPrincipal1];
        let result = AdminModel.validateNewAdmin(testPrincipal2, admins);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );
  },
);

suite(
  "AdminModel - validateNewMember",
  func() {
    test(
      "accepts valid new member",
      func() {
        let members : [Principal] = [];
        let result = AdminModel.validateNewMember(testPrincipal1, members);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );

    test(
      "rejects principal already in member list",
      func() {
        let members : [Principal] = [testPrincipal1];
        let result = AdminModel.validateNewMember(testPrincipal1, members);
        expect.result<(), Text>(result, resultToText, resultEqual).equal(
          #err("Principal is already a member.")
        );
      },
    );

    test(
      "accepts principal not in existing member list",
      func() {
        let members : [Principal] = [testPrincipal1];
        let result = AdminModel.validateNewMember(testPrincipal2, members);
        expect.result<(), Text>(result, resultToText, resultEqual).isOk();
      },
    );
  },
);

suite(
  "AdminModel - List Operations",
  func() {
    test(
      "addAdminToList appends admin to empty list",
      func() {
        let admins : [Principal] = [];
        let newAdmins = AdminModel.addAdminToList(testPrincipal1, admins);
        expect.nat(newAdmins.size()).equal(1);
        expect.bool(newAdmins[0] == testPrincipal1).equal(true);
      },
    );

    test(
      "addAdminToList appends admin to existing list",
      func() {
        let admins : [Principal] = [testPrincipal1];
        let newAdmins = AdminModel.addAdminToList(testPrincipal2, admins);
        expect.nat(newAdmins.size()).equal(2);
        expect.bool(newAdmins[0] == testPrincipal1).equal(true);
        expect.bool(newAdmins[1] == testPrincipal2).equal(true);
      },
    );

    test(
      "addMemberToList appends member to empty list",
      func() {
        let members : [Principal] = [];
        let newMembers = AdminModel.addMemberToList(testPrincipal1, members);
        expect.nat(newMembers.size()).equal(1);
        expect.bool(newMembers[0] == testPrincipal1).equal(true);
      },
    );

    test(
      "addMemberToList appends member to existing list",
      func() {
        let members : [Principal] = [testPrincipal1];
        let newMembers = AdminModel.addMemberToList(testPrincipal2, members);
        expect.nat(newMembers.size()).equal(2);
        expect.bool(newMembers[0] == testPrincipal1).equal(true);
        expect.bool(newMembers[1] == testPrincipal2).equal(true);
      },
    );
  },
);

suite(
  "AdminModel - Query Helpers",
  func() {
    test(
      "isAdmin returns true for admin in list",
      func() {
        let admins : [Principal] = [testPrincipal1, testPrincipal2];
        expect.bool(AdminModel.isAdmin(testPrincipal1, admins)).equal(true);
        expect.bool(AdminModel.isAdmin(testPrincipal2, admins)).equal(true);
      },
    );

    test(
      "isAdmin returns false for principal not in list",
      func() {
        let admins : [Principal] = [testPrincipal1];
        expect.bool(AdminModel.isAdmin(testPrincipal2, admins)).equal(false);
      },
    );

    test(
      "isAdmin returns false for empty list",
      func() {
        let admins : [Principal] = [];
        expect.bool(AdminModel.isAdmin(testPrincipal1, admins)).equal(false);
      },
    );

    test(
      "isMember returns true for member in list",
      func() {
        let members : [Principal] = [testPrincipal1, testPrincipal2];
        expect.bool(AdminModel.isMember(testPrincipal1, members)).equal(true);
        expect.bool(AdminModel.isMember(testPrincipal2, members)).equal(true);
      },
    );

    test(
      "isMember returns false for principal not in list",
      func() {
        let members : [Principal] = [testPrincipal1];
        expect.bool(AdminModel.isMember(testPrincipal2, members)).equal(false);
      },
    );

    test(
      "isMember returns false for empty list",
      func() {
        let members : [Principal] = [];
        expect.bool(AdminModel.isMember(testPrincipal1, members)).equal(false);
      },
    );
  },
);
