import Json "mo:json";
import { str; obj } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import List "mo:core/List";
import ToolTypes "../tools/tool-types";

module {

  type CallCore = ToolTypes.CallCore;

  // ── Handlers ───────────────────────────────────────────────────────

  /// List all agents. → GET /agent
  public func listAgents(callCore : CallCore, _args : Text) : async Text {
    handleResult(await callCore(#get, "/agent", "{}"));
  };

  /// Get an agent by ID. → GET /agent/{id}
  public func getAgent(callCore : CallCore, args : Text) : async Text {
    switch (parseNatField(args, "id")) {
      case (#err(e)) { errorJson(e) };
      case (#ok(id)) {
        handleResult(await callCore(#get, "/agent/" # Nat.toText(id), "{}"));
      };
    };
  };

  /// Register a new agent. → POST /agent
  /// Forwards name, model, workspaceId, allowedChannelIds to Core.
  public func registerAgent(callCore : CallCore, args : Text) : async Text {
    handleResult(await callCore(#post, "/agent", args));
  };

  /// Update an agent by ID. → POST /agent/{id}
  /// Extracts ID from args, forwards remaining fields to Core.
  public func updateAgent(callCore : CallCore, args : Text) : async Text {
    switch (parseNatField(args, "id")) {
      case (#err(e)) { errorJson(e) };
      case (#ok(id)) {
        // Remove "id" from body — Core uses the path param
        let body = removeField(args, "id");
        handleResult(await callCore(#post, "/agent/" # Nat.toText(id), body));
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

  /// Remove a single field from a JSON object string.
  private func removeField(jsonStr : Text, field : Text) : Text {
    switch (Json.parse(jsonStr)) {
      case (#ok(#object_(entries))) {
        let filtered = List.empty<(Text, Json.Json)>();
        for ((k, v) in entries.vals()) {
          if (k != field) {
            List.add(filtered, (k, v));
          };
        };
        Json.stringify(obj(List.toArray(filtered)), null);
      };
      case (_) { jsonStr };
    };
  };
};
