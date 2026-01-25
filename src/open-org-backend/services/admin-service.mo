import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {
  // ============================================
  // Business Validation
  // ============================================

  /// Validate a new admin before adding to a list.
  /// Checks: not anonymous, not already in list.
  public func validateNewAdmin(newAdmin : Principal, admins : [Principal]) : Result.Result<(), Text> {
    if (Principal.isAnonymous(newAdmin)) {
      return #err("Anonymous users cannot be admins");
    };

    if (isInList(newAdmin, admins)) {
      #err("Principal is already an admin");
    } else {
      #ok(());
    };
  };

  /// Validate a new member before adding to a list.
  /// Checks: not anonymous, not already in list.
  public func validateNewMember(newMember : Principal, members : [Principal]) : Result.Result<(), Text> {
    if (Principal.isAnonymous(newMember)) {
      return #err("Anonymous users cannot be members");
    };

    if (isInList(newMember, members)) {
      #err("Principal is already a member");
    } else {
      #ok(());
    };
  };

  // ============================================
  // List Operations
  // ============================================

  /// Add a new admin to the list
  public func addAdminToList(newAdmin : Principal, admins : [Principal]) : [Principal] {
    Array.concat(admins, [newAdmin]);
  };

  /// Add a new member to the list
  public func addMemberToList(newMember : Principal, members : [Principal]) : [Principal] {
    Array.concat(members, [newMember]);
  };

  // ============================================
  // Query Helpers
  // ============================================

  /// Check if a principal is in a list of admins
  public func isAdmin(principal : Principal, admins : [Principal]) : Bool {
    isInList(principal, admins);
  };

  /// Check if a principal is in a list of members
  public func isMember(principal : Principal, members : [Principal]) : Bool {
    isInList(principal, members);
  };

  // ============================================
  // Private Helpers
  // ============================================

  private func isInList(principal : Principal, list : [Principal]) : Bool {
    for (p in list.vals()) {
      if (p == principal) {
        return true;
      };
    };
    false;
  };
};
