import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import List "mo:core/List";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import Types "../../../types";

module {
  private func parseSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("groqApiKey") { ?#groqApiKey };
      case ("openaiApiKey") { ?#openaiApiKey };
      case ("slackBotToken") { ?#slackBotToken };
      case _ { null };
    };
  };

  private func parseSecretsAllowed(items : [Json.Json]) : ?[(Nat, Types.SecretId)] {
    let buffer = List.empty<(Nat, Types.SecretId)>();
    for (item in items.vals()) {
      let wsIdOpt = switch (Json.get(item, "workspaceId")) {
        case (?#number(#int n)) { if (n >= 0) ?Int.abs(n) else null };
        case _ { null };
      };
      let sidOpt = switch (Json.get(item, "secretId")) {
        case (?#string(s)) { parseSecretId(s) };
        case _ { null };
      };
      switch (wsIdOpt, sidOpt) {
        case (?wsId, ?sid) { List.add(buffer, (wsId, sid)) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };

  private func parseExecutionType(json : Json.Json) : ?AgentModel.AgentExecutionType {
    let typeStr = switch (Json.get(json, "type")) {
      case (?#string(s)) { s };
      case _ { return null };
    };
    switch (typeStr) {
      case ("api") { ?#api };
      case ("runtime") {
        let hostingStr = switch (Json.get(json, "hosting")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        let frameworkStr = switch (Json.get(json, "framework")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        switch (hostingStr, frameworkStr) {
          case ("codespace", "openClaw") {
            ?#runtime {
              hosting = #codespace;
              framework = #openClaw { deployedVersion = null };
            };
          };
          case _ { null };
        };
      };
      case _ { null };
    };
  };

  public func handle(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
  ) : async Text {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        return Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {};
    };

    switch (Json.parse(args)) {
      case (#err(e)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show e);
      };
      case (#ok(json)) {
        let originalId = switch (Json.get(json, "originalId")) {
          case (?#number(#int n)) {
            if (n >= 0) { Int.abs(n) } else {
              return Helpers.buildErrorResponse("originalId must be a non-negative integer");
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: originalId");
          };
        };

        let newName = switch (Json.get(json, "newName")) {
          case (?#string(s)) { s };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: newName");
          };
        };

        let targetWorkspaceId = switch (Json.get(json, "targetWorkspaceId")) {
          case (?#number(#int n)) {
            if (n >= 0) { Int.abs(n) } else {
              return Helpers.buildErrorResponse("targetWorkspaceId must be a non-negative integer");
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: targetWorkspaceId");
          };
        };

        let secretsAllowed = switch (Json.get(json, "secretsAllowed")) {
          case (?#array(items)) {
            switch (parseSecretsAllowed(items)) {
              case (?sa) { sa };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid secretsAllowed: each entry must have workspaceId (number) and secretId (string)."
                );
              };
            };
          };
          case (null) { [] };
          case _ {
            return Helpers.buildErrorResponse("secretsAllowed must be an array");
          };
        };

        let executionType = switch (Json.get(json, "executionType")) {
          case (?etJson) {
            switch (parseExecutionType(etJson)) {
              case (?et) { ?et };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid executionType. Use {\"type\":\"api\"} or {\"type\":\"runtime\",\"hosting\":\"codespace\",\"framework\":\"openClaw\"}."
                );
              };
            };
          };
          case (null) { null }; // null = inherit execution type from original
        };

        switch (AgentModel.forkAgent(state, originalId, newName, targetWorkspaceId, secretsAllowed, executionType)) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok(id)) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("id", int(id)),
                ("name", str(newName)),
                ("message", str("Agent '" # newName # "' forked from ID " # Nat.toText(originalId) # " with new ID " # Nat.toText(id))),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
