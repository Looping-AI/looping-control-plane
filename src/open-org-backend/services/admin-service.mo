import Array "mo:core/Array";
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

  // Add a new admin to the list
  public func addAdminToList(newAdmin : Principal, admins : [Principal]) : [Principal] {
    Array.concat(admins, [newAdmin]);
  };

  private func getAnonymousPrincipal() : Principal {
    Principal.fromText("2vxsx-fae");
  };
};
