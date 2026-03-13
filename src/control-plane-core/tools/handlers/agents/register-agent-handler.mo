import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import List "mo:core/List";
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
        let name = switch (Json.get(json, "name")) {
          case (?#string(s)) { s };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: name");
          };
        };

        let category = switch (Json.get(json, "category")) {
          case (?#string(s)) {
            switch (parseCategory(s)) {
              case (?c) { c };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid category: " # s # ". Must be admin, planning, research, or communication."
                );
              };
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: category");
          };
        };

        let llmModel = switch (Json.get(json, "llmModel")) {
          case (?#string(s)) {
            switch (parseLlmModel(s)) {
              case (?m) { m };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid llmModel: " # s # ". Supported values: gpt_oss_120b."
                );
              };
            };
          };
          case (null) { #groq(#gpt_oss_120b) };
          case _ { return Helpers.buildErrorResponse("Invalid llmModel field") };
        };

        let workspaceId = switch (Json.get(json, "workspaceId")) {
          case (?#number(#int n)) {
            if (n >= 0) { Int.abs(n) } else {
              return Helpers.buildErrorResponse("workspaceId must be a non-negative integer");
            };
          };
          case (null) { 0 }; // default to org workspace (0)
          case _ { return Helpers.buildErrorResponse("workspaceId must be a number") };
        };

        let executionType = switch (Json.get(json, "executionType")) {
          case (?etJson) {
            switch (parseExecutionType(etJson)) {
              case (?et) { et };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid executionType. Use {\"type\":\"api\"} or {\"type\":\"runtime\",\"hosting\":\"codespace\",\"framework\":\"openClaw\"}."
                );
              };
            };
          };
          case (null) {
            // default for new user-created agents
            #runtime { hosting = #codespace; framework = #openClaw { deployedVersion = null } };
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

        let toolsDisallowed = switch (Json.get(json, "toolsDisallowed")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { a };
              case null {
                return Helpers.buildErrorResponse("toolsDisallowed must be an array of strings");
              };
            };
          };
          case (null) { [] };
          case _ {
            return Helpers.buildErrorResponse("toolsDisallowed must be an array");
          };
        };

        let toolsMisconfigured = switch (Json.get(json, "toolsMisconfigured")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { a };
              case null {
                return Helpers.buildErrorResponse("toolsMisconfigured must be an array of strings");
              };
            };
          };
          case (null) { [] };
          case _ {
            return Helpers.buildErrorResponse("toolsMisconfigured must be an array");
          };
        };

        let sources = switch (Json.get(json, "sources")) {
          case (?#array(items)) {
            switch (parseStringArray(items)) {
              case (?a) { a };
              case null {
                return Helpers.buildErrorResponse("sources must be an array of strings");
              };
            };
          };
          case (null) { [] };
          case _ {
            return Helpers.buildErrorResponse("sources must be an array");
          };
        };

        switch (
          AgentModel.register(
            name,
            workspaceId,
            category,
            llmModel,
            executionType,
            secretsAllowed,
            toolsDisallowed,
            toolsMisconfigured,
            Map.empty<Text, AgentModel.ToolState>(),
            sources,
            state,
          )
        ) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok(id)) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("id", int(id)),
                ("name", str(name)),
                ("message", str("Agent '" # name # "' registered with ID " # Nat.toText(id))),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
