import Json "mo:json";
import { obj } "mo:json";
import { str } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import List "mo:core/List";
import ToolTypes "../tools/tool-types";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ───────────────────────────────────────────────────────

  /// List all agents. → GET /agent
  public func listAgents(wrapper : Wrapper, _args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#get, "/agent", "{}"));
  };

  /// Get an agent by ID. → GET /agent/{id}
  public func getAgent(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    switch (parseNatField(args, "id")) {
      case (#err(e)) { #err(e) };
      case (#ok(id)) {
        handleResult(await wrapper.callCore(#get, "/agent/" # Nat.toText(id), "{}"));
      };
    };
  };

  /// Register a new agent. → POST /agent
  /// Forwards name, model, workspaceId, allowedChannelIds to Core.
  public func registerAgent(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#post, "/agent", args));
  };

  /// Update an agent by ID. → POST /agent/{id}
  /// Extracts ID from args, forwards remaining fields to Core.
  public func updateAgent(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    switch (parseNatField(args, "id")) {
      case (#err(e)) { #err(e) };
      case (#ok(id)) {
        // Remove "id" from body — Core uses the path param
        let body = removeField(args, "id");
        handleResult(await wrapper.callCore(#post, "/agent/" # Nat.toText(id), body));
      };
    };
  };

  /// Unregister (delete) an agent by ID. → DELETE /agent/{id}
  public func unregisterAgent(wrapper : Wrapper, args : Text) : async ToolTypes.ToolCallOutcome {
    switch (parseNatField(args, "id")) {
      case (#err(e)) { #err(e) };
      case (#ok(id)) {
        handleResult(await wrapper.callCore(#delete, "/agent/" # Nat.toText(id), "{}"));
      };
    };
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
          case (?#number(#float(f))) {
            let n = Float.toInt(f);
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
