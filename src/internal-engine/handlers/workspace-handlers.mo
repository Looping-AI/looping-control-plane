import Json "mo:json";
import { str; obj } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import ToolTypes "../tool-types";

module {

  type CallCore = ToolTypes.CallCore;

  // ── Handlers ───────────────────────────────────────────────────────

  /// List all workspaces. → GET /workspace
  public func listWorkspaces(callCore : CallCore, _args : Text) : async Text {
    handleResult(await callCore(#get, "/workspace", "{}"));
  };

  /// Create a workspace with the given name. → POST /workspace
  public func createWorkspace(callCore : CallCore, args : Text) : async Text {
    handleResult(await callCore(#post, "/workspace", args));
  };

  /// Delete a workspace by ID. → DELETE /workspace/{id}
  public func deleteWorkspace(callCore : CallCore, args : Text) : async Text {
    switch (parseNatField(args, "workspaceId")) {
      case (#err(e)) { errorJson(e) };
      case (#ok(id)) {
        handleResult(await callCore(#delete, "/workspace/" # Nat.toText(id), "{}"));
      };
    };
  };

  /// Set the admin channel for a workspace. → POST /workspace/{id}
  /// NOTE: Simplified — forwards channelId in body. Core route currently
  /// only supports name updates; this will be extended in a follow-up.
  public func setWorkspaceAdminChannel(callCore : CallCore, args : Text) : async Text {
    switch (parseNatField(args, "workspaceId")) {
      case (#err(e)) { errorJson(e) };
      case (#ok(id)) {
        handleResult(await callCore(#post, "/workspace/" # Nat.toText(id), args));
      };
    };
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
          case (?#number(#float(f))) {
            let n = Float.toInt(f);
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
