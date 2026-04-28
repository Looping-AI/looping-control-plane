import Json "mo:json";
import { obj } "mo:json";
import { str } "mo:json";
import Nat "mo:core/Nat";
import ToolTypes "../tools/tool-types";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ───────────────────────────────────────────────────────

  /// Get the current workspace. → GET /workspace
  public func getWorkspace(wrapper : Wrapper, _args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#get, "/workspace", "{}"));
  };

  /// Create a workspace with the given name. → POST /workspace
  public func createWorkspace(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#post, "/workspace", args));
  };

  /// Delete a workspace by ID. → DELETE /workspace/{id}
  public func deleteWorkspace(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    switch (parseNatField(args, "workspaceId")) {
      case (#err(e)) { #err(e) };
      case (#ok(id)) {
        handleResult(await wrapper.callCore(#delete, "/workspace/" # Nat.toText(id), "{}"));
      };
    };
  };

  /// Set the admin channel for the token's workspace. → POST /workspace/admin-channel
  public func setWorkspaceAdminChannel(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#post, "/workspace/admin-channel", args));
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : ToolTypes.ToolCallOutcome {
    switch (result) {
      case (#ok(data)) { #ok(data) };
      case (#err(e)) { #err(e) };
    };
  };

  private func parseNatField(args : Text, field : Text) : {
    #ok : Nat;
    #err : Text;
  } {
    switch (Json.parse(args)) {
      case (#err(_)) {
        #err(Json.stringify(obj([("type", str("parseError")), ("message", str("Invalid JSON arguments."))]), null));
      };
      case (#ok(parsed)) {
        switch (Json.get(parsed, field)) {
          case (?#number(#int(n))) {
            if (n < 0) {
              #err(Json.stringify(obj([("type", str("invalidValue")), ("message", str("'" # field # "' must be non-negative."))]), null));
            } else {
              #ok(Nat.fromInt(n));
            };
          };
          case (_) {
            #err(Json.stringify(obj([("type", str("missingField")), ("message", str("Missing or invalid '" # field # "' field."))]), null));
          };
        };
      };
    };
  };
};
