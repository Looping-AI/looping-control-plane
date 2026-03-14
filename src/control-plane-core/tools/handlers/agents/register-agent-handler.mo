import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import AgentParsers "../parsers/agent-parsers";

module {
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
            switch (AgentParsers.parseCategory(s)) {
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
            switch (AgentParsers.parseLlmModel(s)) {
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
          case _ {
            return Helpers.buildErrorResponse("workspaceId must be a number");
          };
        };

        let executionType = switch (Json.get(json, "executionType")) {
          case (?etJson) {
            switch (AgentParsers.parseExecutionType(etJson)) {
              case (?et) { et };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid executionType. Use {\"type\":\"api\"} or {\"type\":\"runtime\",\"hosting\":\"codespace\",\"framework\":\"openClaw\"}."
                );
              };
            };
          };
          case (null) {
            return Helpers.buildErrorResponse(
              "Missing required field: executionType. Use {\"type\":\"api\"} or {\"type\":\"runtime\",\"hosting\":\"codespace\",\"framework\":\"openClaw\"}."
            );
          };
        };

        let secretsAllowed = switch (Json.get(json, "secretsAllowed")) {
          case (?#array(items)) {
            switch (AgentParsers.parseSecretsAllowed(items)) {
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
            switch (Helpers.parseStringArray(items)) {
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
            switch (Helpers.parseStringArray(items)) {
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
            switch (Helpers.parseStringArray(items)) {
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
