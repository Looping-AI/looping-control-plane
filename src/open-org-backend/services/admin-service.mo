import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {
  // Check if a principal is an admin
  public func isAdmin(principal : Principal, admins : [Principal]) : Bool {
    for (admin in admins.vals()) {
      if (admin == principal) {
        return true;
      };
    };
    false;
  };

  // Check if a principal is admin in a specific workspace
  public func isWorkspaceAdmin(caller : Principal, workspaceId : Nat, workspaceAdmins : Map.Map<Nat, [Principal]>) : Bool {
    switch (Map.get(workspaceAdmins, Nat.compare, workspaceId)) {
      case (null) { false };
      case (?admins) {
        isAdmin(caller, admins);
      };
    };
  };

  // Validate new admin before adding (requires owner)
  public func validateNewAdminAsOwner(newAdmin : Principal, caller : Principal, owner : Principal, admins : [Principal]) : Result.Result<(), Text> {
    if (caller != owner) {
      return #err("Only the owner can add admins");
    };

    if (newAdmin == getAnonymousPrincipal()) {
      return #err("Anonymous users cannot be admins");
    };

    if (isAdmin(newAdmin, admins)) {
      #err("Principal is already an admin");
    } else {
      #ok(());
    };
  };

  // Validate new workspace admin before adding
  public func validateNewWorkspaceAdmin(newAdmin : Principal, caller : Principal, orgOwner : Principal, workspaceId : Nat, workspaceAdmins : Map.Map<Nat, [Principal]>) : Result.Result<(), Text> {
    // Check if caller is owner or existing workspace admin
    if (caller != orgOwner and not isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only the owner or workspace admins can add workspace admins");
    };

    if (newAdmin == getAnonymousPrincipal()) {
      return #err("Anonymous users cannot be admins");
    };

    switch (Map.get(workspaceAdmins, Nat.compare, workspaceId)) {
      case (null) {
        #err("Workspace not found");
      };
      case (?admins) {
        if (isAdmin(newAdmin, admins)) {
          #err("Principal is already a workspace admin");
        } else {
          #ok(());
        };
      };
    };
  };

  // Check if a principal is a member in a specific workspace
  public func isWorkspaceMember(caller : Principal, workspaceId : Nat, workspaceMembers : Map.Map<Nat, [Principal]>) : Bool {
    switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
      case (null) { false };
      case (?members) {
        isMember(caller, members);
      };
    };
  };

  // Check if a principal is a member
  private func isMember(principal : Principal, members : [Principal]) : Bool {
    for (member in members.vals()) {
      if (member == principal) {
        return true;
      };
    };
    false;
  };

  // Validate new workspace member before adding
  public func validateNewWorkspaceMember(
    newMember : Principal,
    caller : Principal,
    orgOwner : Principal,
    workspaceId : Nat,
    workspaceAdmins : Map.Map<Nat, [Principal]>,
    workspaceMembers : Map.Map<Nat, [Principal]>,
  ) : Result.Result<(), Text> {
    // Check if caller is owner or existing workspace admin
    if (caller != orgOwner and not isWorkspaceAdmin(caller, workspaceId, workspaceAdmins)) {
      return #err("Only the owner or workspace admins can add workspace members");
    };

    if (newMember == getAnonymousPrincipal()) {
      return #err("Anonymous users cannot be members");
    };

    switch (Map.get(workspaceMembers, Nat.compare, workspaceId)) {
      case (null) {
        #err("Workspace not found");
      };
      case (?members) {
        if (isMember(newMember, members)) {
          #err("Principal is already a workspace member");
        } else {
          #ok(());
        };
      };
    };
  };

  // Add a new admin to the list
  public func addAdminToList(newAdmin : Principal, admins : [Principal]) : [Principal] {
    Array.concat(admins, [newAdmin]);
  };

  // Add a new member to the list
  public func addMemberToList(newMember : Principal, members : [Principal]) : [Principal] {
    Array.concat(members, [newMember]);
  };

  private func getAnonymousPrincipal() : Principal {
    Principal.fromText("2vxsx-fae");
  };
};
