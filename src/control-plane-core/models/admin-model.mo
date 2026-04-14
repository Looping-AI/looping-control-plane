import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {
  // ============================================
  // Business Validation
  // ============================================

  /// Validate a new admin before adding to a list.
  /// Checks: not anonymous, not already in list.
  public func validateNewAdmin(admins : [Principal], newAdmin : Principal) : Result.Result<(), Text> {
    if (Principal.isAnonymous(newAdmin)) {
      return #err("Anonymous users cannot be admins.");
    };

    if (isInList(admins, newAdmin)) {
      #err("Principal is already an admin.");
    } else {
      #ok(());
    };
  };

  /// Validate a new member before adding to a list.
  /// Checks: not anonymous, not already in list.
  public func validateNewMember(members : [Principal], newMember : Principal) : Result.Result<(), Text> {
    if (Principal.isAnonymous(newMember)) {
      return #err("Anonymous users cannot be members.");
    };

    if (isInList(members, newMember)) {
      #err("Principal is already a member.");
    } else {
      #ok(());
    };
  };

  // ============================================
  // List Operations
  // ============================================

  /// Add a new admin to the list
  public func addAdminToList(admins : [Principal], newAdmin : Principal) : [Principal] {
    Array.concat(admins, [newAdmin]);
  };

  /// Add a new member to the list
  public func addMemberToList(members : [Principal], newMember : Principal) : [Principal] {
    Array.concat(members, [newMember]);
  };

  // ============================================
  // Query Helpers
  // ============================================

  /// Check if a principal is in a list of admins
  public func isAdmin(admins : [Principal], principal : Principal) : Bool {
    isInList(admins, principal);
  };

  /// Check if a principal is in a list of members
  public func isMember(members : [Principal], principal : Principal) : Bool {
    isInList(members, principal);
  };

  // ============================================
  // Private Helpers
  // ============================================

  private func isInList(list : [Principal], principal : Principal) : Bool {
    for (p in list.vals()) {
      if (p == principal) {
        return true;
      };
    };
    false;
  };
};
