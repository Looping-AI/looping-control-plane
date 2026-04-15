import Json "mo:json";
import { str; arr } "mo:json";
import Array "mo:core/Array";
import List "mo:core/List";
import Set "mo:core/Set";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import AgentModel "../../../models/agent-model";
import Types "../../../types";

module {
  /// Parse an [ExecutionEngine] array from a JSON array of strings.
  /// Accepts "api", "canister", and "github"; returns null on any unknown value.
  public func parseExecutionEngines(items : [Json.Json]) : ?[AgentModel.ExecutionEngine] {
    let buffer = List.empty<AgentModel.ExecutionEngine>();
    for (item in items.vals()) {
      switch (item) {
        case (#string("api")) { List.add(buffer, #api) };
        case (#string("canister")) { List.add(buffer, #canister) };
        case (#string("github")) { List.add(buffer, #github) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };

  /// Parse a SecretId for agent use. Excludes platform secrets
  /// (`#slackBotToken` and `#slackSigningSecret`) which are infrastructure
  /// credentials managed exclusively by org-level admins.
  public func parseAgentSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("openRouterApiKey") { ?#openRouterApiKey };
      case ("anthropicApiKey") { ?#anthropicApiKey };
      case ("anthropicSetupToken") { ?#anthropicSetupToken };
      case _ {
        // Accept "custom:<name>" as #custom(name)
        if (Text.startsWith(s, #text "custom:")) {
          let name = Text.fromIter(Iter.drop(Text.toIter(s), 7));
          if (name == "") { null } else { ?#custom(name) };
        } else { null };
      };
    };
  };

  public func parseSecretsAllowed(items : [Json.Json]) : ?[(Nat, Types.SecretId)] {
    let buffer = List.empty<(Nat, Types.SecretId)>();
    for (item in items.vals()) {
      let wsIdOpt = switch (Json.get(item, "workspaceId")) {
        case (?#number(#int n)) { if (n >= 0) ?Int.abs(n) else null };
        case _ { null };
      };
      let sidOpt = switch (Json.get(item, "secretId")) {
        case (?#string(s)) { parseAgentSecretId(s) };
        case _ { null };
      };
      switch (wsIdOpt, sidOpt) {
        case (?wsId, ?sid) { List.add(buffer, (wsId, sid)) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };

  /// Parse secretOverrides: [{"secretId":"...","customKeyName":"..."}]
  /// Each entry maps a standard SecretId to a custom key name within the agent's workspace.
  public func parseSecretOverrides(items : [Json.Json]) : ?[(Types.SecretId, Text)] {
    let buffer = List.empty<(Types.SecretId, Text)>();
    for (item in items.vals()) {
      let sidOpt = switch (Json.get(item, "secretId")) {
        case (?#string(s)) {
          // Overrides are only meant for standard (non-#custom) SecretId values.
          // Filter out any custom:<name> IDs parsed as #custom(_).
          switch (parseAgentSecretId(s)) {
            case (?#custom(_)) { null };
            case (other) { other };
          };
        };
        case _ { null };
      };
      let nameOpt = switch (Json.get(item, "customKeyName")) {
        case (?#string(s)) { if (s == "") null else ?s };
        case _ { null };
      };
      switch (sidOpt, nameOpt) {
        case (?sid, ?name) { List.add(buffer, (sid, name)) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };

  /// Parse an array of JSON strings into a Set<Text>.
  /// Returns null if any element is not a string.
  public func parseAllowedChannelIds(items : [Json.Json]) : ?Set.Set<Text> {
    let set = Set.empty<Text>();
    for (item in items.vals()) {
      switch (item) {
        case (#string(s)) { Set.add(set, Text.compare, s) };
        case _ { return null };
      };
    };
    ?set;
  };

  /// Serialize a Set<Text> to a JSON array (values in ascending order).
  public func allowedChannelIdsToJson(set : Set.Set<Text>) : Json.Json {
    arr(Array.map<Text, Json.Json>(Set.toArray(set), str));
  };
};
