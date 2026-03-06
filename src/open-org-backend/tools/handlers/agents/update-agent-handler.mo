import Json "mo:json";
import { str; obj; bool } "mo:json";
import List "mo:core/List";
import Int "mo:core/Int";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import Types "../../../types";

module {
  private func parseCategory(s : Text) : ?AgentModel.AgentCategory {
    switch (s) {
      case ("admin") { ?#admin };
      case ("planning") { ?#planning };
      case ("research") { ?#research };
      case ("communication") { ?#communication };
      case _ { null };
    };
  };

  private func parseLlmModel(s : Text) : ?AgentModel.LlmModel {
    switch (s) {
      case ("gpt_oss_120b") { ?#groq(#gpt_oss_120b) };
      case ("groq:gpt_oss_120b") { ?#groq(#gpt_oss_120b) };
      case _ { null };
    };
  };

  private func parseSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("groqApiKey") { ?#groqApiKey };
      case ("openaiApiKey") { ?#openaiApiKey };
      case ("slackSigningSecret") { ?#slackSigningSecret };
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

  private func parseStringArray(items : [Json.Json]) : ?[Text] {
    let buffer = List.empty<Text>();
    for (item in items.vals()) {
      switch (item) {
        case (#string(s)) { List.add(buffer, s) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
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
        let id = switch (Json.get(json, "id")) {
          case (?#number(#int n)) {
            if (n >= 0) { Int.abs(n) } else {
              return Helpers.buildErrorResponse("id must be a non-negative integer");
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: id");
          };
        };

        let newName = switch (Json.get(json, "name")) {
          case (?#string(s)) { ?s };
          case (null) { null };
          case _ { return Helpers.buildErrorResponse("name must be a string") };
        };

        let newCategory = switch (Json.get(json, "category")) {
          case (?#string(s)) {
            switch (parseCategory(s)) {
              case (?c) { ?c };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid category: " # s # ". Must be admin, planning, research, or communication."
                );
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("category must be a string");
          };
        };

        let newLlmModel = switch (Json.get(json, "llmModel")) {
          case (?#string(s)) {
            switch (parseLlmModel(s)) {
              case (?m) { ?m };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid llmModel: " # s # ". Supported values: gpt_oss_120b."
                );
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("llmModel must be a string");
          };
        };

        let newSecretsAllowed = switch (Json.get(json, "secretsAllowed")) {
          case (?#array(items)) {
            switch (parseSecretsAllowed(items)) {
              case (?sa) { ?sa };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid secretsAllowed: each entry must have workspaceId (number) and secretId (string)."
                );
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("secretsAllowed must be an array");
          };
        };

        let newToolsDisallowed = switch (Json.get(json, "toolsDisallowed")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { ?a };
              case null {
                return Helpers.buildErrorResponse("toolsDisallowed must be an array of strings");
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("toolsDisallowed must be an array");
          };
        };

        let newToolsMisconfigured = switch (Json.get(json, "toolsMisconfigured")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { ?a };
              case null {
                return Helpers.buildErrorResponse("toolsMisconfigured must be an array of strings");
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("toolsMisconfigured must be an array");
          };
        };

        let newSources = switch (Json.get(json, "sources")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { ?a };
              case null {
                return Helpers.buildErrorResponse("sources must be an array of strings");
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("sources must be an array");
          };
        };

        switch (
          AgentModel.updateById(
            id,
            newName,
            newCategory,
            newLlmModel,
            newSecretsAllowed,
            newToolsDisallowed,
            newToolsMisconfigured,
            null,
            newSources,
            state,
          )
        ) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok(_)) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("message", str("Agent updated successfully")),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
