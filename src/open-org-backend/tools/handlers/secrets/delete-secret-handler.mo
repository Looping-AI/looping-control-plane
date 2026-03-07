import Json "mo:json";
import { str; obj; bool } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import SecretModel "../../../models/secret-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Types "../../../types";
import Helpers "../handler-helpers";

module {
  /// Delete a specific secret from a workspace.
  ///
  /// JSON args: { workspaceId: number, secretId: string }
  ///
  /// Authorization:
  ///   - Slack secrets (slackBotToken, slackSigningSecret): requires #IsPrimaryOwner or #IsOrgAdmin
  ///   - LLM keys (groqApiKey, openaiApiKey): requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsMap,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let wsIdOpt : ?Nat = switch (Json.get(json, "workspaceId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let secretIdOpt : ?Types.SecretId = switch (Json.get(json, "secretId")) {
          case (?#string("groqApiKey")) { ?#groqApiKey };
          case (?#string("openaiApiKey")) { ?#openaiApiKey };
          case (?#string("slackBotToken")) { ?#slackBotToken };
          case (?#string("slackSigningSecret")) { ?#slackSigningSecret };
          case _ { null };
        };

        switch (wsIdOpt, secretIdOpt) {
          case (?wsId, ?secretId) {
            // Auth: Slack bot token requires org-level; LLM keys allow workspace admin
            let requiredRoles : [SlackAuthMiddleware.AuthStep] = switch (secretId) {
              case (#slackBotToken or #slackSigningSecret) {
                [#IsPrimaryOwner, #IsOrgAdmin];
              };
              case (#groqApiKey or #openaiApiKey) {
                [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(wsId)];
              };
            };
            switch (SlackAuthMiddleware.authorize(uac, requiredRoles)) {
              case (#err(msg)) {
                Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {
                switch (SecretModel.deleteSecret(secrets, wsId, secretId)) {
                  case (#err(msg)) { Helpers.buildErrorResponse(msg) };
                  case (#ok(())) {
                    Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("message", str("Secret deleted successfully.")),
                      ]),
                      null,
                    );
                  };
                };
              };
            };
          };
          case (null, _) {
            Helpers.buildErrorResponse("Missing required field: workspaceId");
          };
          case (_, _) {
            Helpers.buildErrorResponse("Invalid secretId. Must be one of: groqApiKey, openaiApiKey, slackSigningSecret, slackBotToken");
          };
        };
      };
    };
  };
};
