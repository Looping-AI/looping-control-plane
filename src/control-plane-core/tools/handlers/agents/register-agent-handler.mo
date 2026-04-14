import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import SlackWrapper "../../../wrappers/slack-wrapper";
import Helpers "../handler-helpers";
import AgentParsers "../parsers/agent-parsers";

module {
  public func handle(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
    validateModel : ?(Text -> async Bool),
    resolveSlackBotToken : ?(Text -> ?Text),
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
                  "Invalid category: " # s # ". Must be admin, onboarding, or custom."
                );
              };
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: category");
          };
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

        switch (executionType) {
          case (#api({ model })) {
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

        let secretOverrides = switch (Json.get(json, "secretOverrides")) {
          case (?#array(items)) {
            switch (AgentParsers.parseSecretOverrides(items)) {
              case (?so) { so };
              case null {
                return Helpers.buildErrorResponse(
                  "Invalid secretOverrides: each entry must have secretId (string) and customKeyName (non-empty string)."
                );
              };
            };
          };
          case (null) { [] };
          case _ {
            return Helpers.buildErrorResponse("secretOverrides must be an array");
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

        let allowedChannelIds = switch (Json.get(json, "allowedChannelIds")) {
          case (?#array(items)) {
            switch (AgentParsers.parseAllowedChannelIds(items)) {
              case (?s) {
                if (Set.size(s) == 0) {
                  return Helpers.buildErrorResponse("allowedChannelIds must be a non-empty array of channel ID strings");
                };
                s;
              };
              case null {
                return Helpers.buildErrorResponse("allowedChannelIds must be an array of strings");
              };
            };
          };
          case (null) {
            return Helpers.buildErrorResponse("Missing required field: allowedChannelIds");
          };
          case _ {
            return Helpers.buildErrorResponse("allowedChannelIds must be an array");
          };
        };

        // Validate each channel is accessible by the bot via Slack conversations.info.
        // Skip validation when no resolver is wired (e.g. test canister without cassettes).
        switch (resolveSlackBotToken) {
          case (?resolver) {
            switch (resolver("register-agent-channel-verify")) {
              case (null) {
                return Helpers.buildErrorResponse(
                  "No Slack bot token configured. Store the slackBotToken secret on workspace 0 first."
                );
              };
              case (?botToken) {
                for (channelId in Set.values(allowedChannelIds)) {
                  switch (await SlackWrapper.getChannelInfo(botToken, channelId)) {
                    case (#err(msg)) {
                      return Helpers.buildErrorResponse(
                        "Could not verify channel '" # channelId # "' with Slack: " # msg #
                        ". Ensure the channel exists and the bot has been invited to it."
                      );
                    };
                    case (#ok(_)) {};
                  };
                };
              };
            };
          };
          case (null) {}; // no resolver provided — skip Slack validation
        };

        switch (
          AgentModel.register(
            state,
            name,
            workspaceId,
            category,
            executionType,
            secretsAllowed,
            secretOverrides,
            toolsDisallowed,
            toolsMisconfigured,
            Map.empty<Text, AgentModel.ToolState>(),
            sources,
            allowedChannelIds,
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
