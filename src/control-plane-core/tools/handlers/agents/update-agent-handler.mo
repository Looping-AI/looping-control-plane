import Json "mo:json";
import { str; obj; bool } "mo:json";
import Int "mo:core/Int";
import Set "mo:core/Set";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import AgentParsers "../parsers/agent-parsers";

module {
  public func handle(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
    validateModel : ?(Text -> async Bool),
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
            switch (AgentParsers.parseCategory(s)) {
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

        let newSecretsAllowed = switch (Json.get(json, "secretsAllowed")) {
          case (?#array(items)) {
            switch (AgentParsers.parseSecretsAllowed(items)) {
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

        let newSecretOverrides = switch (Json.get(json, "secretOverrides")) {
          case (?#array(items)) {
            switch (AgentParsers.parseSecretOverrides(items)) {
              case (?so) { ?so };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid secretOverrides: each entry must have secretId (string) and customKeyName (non-empty string)."
                );
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("secretOverrides must be an array");
          };
        };

        let newToolsDisallowed = switch (Json.get(json, "toolsDisallowed")) {
          case (?#array(items)) {
            switch (Helpers.parseStringArray(items)) {
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
            switch (Helpers.parseStringArray(items)) {
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
            switch (Helpers.parseStringArray(items)) {
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

        let newAllowedChannelIds = switch (Json.get(json, "allowedChannelIds")) {
          case (?#array(items)) {
            switch (AgentParsers.parseAllowedChannelIds(items)) {
              case (?s) {
                if (Set.size(s) == 0) {
                  return Helpers.buildErrorResponse("allowedChannelIds must be non-empty when provided; the allowlist cannot be emptied");
                };
                ?s;
              };
              case null {
                return Helpers.buildErrorResponse("allowedChannelIds must be an array of strings");
              };
            };
          };
          case (null) { null };
          case _ {
            return Helpers.buildErrorResponse("allowedChannelIds must be an array");
          };
        };

        let newExecutionType = switch (Json.get(json, "executionType")) {
          case (?etJson) {
            switch (AgentParsers.parseExecutionType(etJson)) {
              case (?et) { ?et };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid executionType. Use {\"type\":\"api\"} or {\"type\":\"runtime\",\"hosting\":\"codespace\",\"framework\":\"openClaw\"}."
                );
              };
            };
          };
          case (null) { null };
        };

        switch (newExecutionType) {
          case (?#api({ model })) {
            switch (validateModel) {
              case (?validator) {
                if (not (await validator(model))) {
                  return Helpers.buildErrorResponse("Invalid or unavailable OpenRouter model: " # model # ". Please use a valid model string.");
                };
              };
              case (null) {};
            };
          };
          case (_) {};
        };

        switch (
          AgentModel.updateById(
            id,
            newName,
            newCategory,
            newExecutionType,
            newSecretsAllowed,
            newSecretOverrides,
            newToolsDisallowed,
            newToolsMisconfigured,
            null,
            newSources,
            newAllowedChannelIds,
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
