import Json "mo:json";
import { str; obj } "mo:json";
import Nat "mo:core/Nat";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ───────────────────────────────────────────────────────

  /// Get the current workspace. → GET /workspace
  public func getWorkspace(wrapper : Wrapper, _args : Text) : async Text {
    handleResult(await wrapper.callCore(#get, "/workspace", "{}"));
  };

  /// Create a workspace with the given name. → POST /workspace
  public func createWorkspace(wrapper : Wrapper, args : Text) : async Text {
    handleResult(await wrapper.callCore(#post, "/workspace", args));
  };

  /// Delete a workspace by ID. → DELETE /workspace/{id}
  public func deleteWorkspace(wrapper : Wrapper, args : Text) : async Text {
    switch (parseNatField(args, "workspaceId")) {
      case (#err(e)) { errorJson(e) };
      case (#ok(id)) {
        handleResult(await wrapper.callCore(#delete, "/workspace/" # Nat.toText(id), "{}"));
      };
    };
  };

  /// Set the admin channel for the token's workspace. → POST /workspace/admin-channel
  public func setWorkspaceAdminChannel(wrapper : Wrapper, args : Text) : async Text {
    handleResult(await wrapper.callCore(#post, "/workspace/admin-channel", args));
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : Text {
    switch (result) {
      case (#ok(data)) { data };
      case (#err(e)) { errorJson(e) };
    };
  };

  private func errorJson(msg : Text) : Text {
    Json.stringify(obj([("error", str(msg))]), null);
  };

  private func parseNatField(args : Text, field : Text) : {
    #ok : Nat;
    #err : Text;
  } {
    switch (Json.parse(args)) {
      case (#err(_)) { #err("Invalid JSON arguments") };
      case (#ok(parsed)) {
        switch (Json.get(parsed, field)) {
          case (?#number(#int(n))) {
            if (n < 0) { #err("'" # field # "' must be non-negative") } else {
              #ok(Nat.fromInt(n));
            };
          };
          case (_) { #err("Missing or invalid '" # field # "' field") };
        };
      };
    };
  };
};
