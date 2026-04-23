import Json "mo:json";
import { str; obj; bool } "mo:json";
import SecretModel "../../../../models/secret-model";
import SlackAuthMiddleware "../../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import SecretParsers "../parsers/secret-parsers";

module {
  /// Delete a specific secret from a workspace.
  ///
  /// `workspaceId` is caller-provided (not from JSON args) to enforce workspace
  /// scoping — the LLM cannot target a different workspace.
  ///
  /// JSON args: { secretId: string }
  ///
  /// Authorization:
  ///   - Slack secrets (slackBotToken, slackSigningSecret): requires #IsPrimaryOwner or #IsOrgAdmin
  ///   - Non-platform secrets (openRouterApiKey, custom:<name>): requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let secretIdOpt = switch (Json.get(json, "secretId")) {
          case (?#string(s)) { SecretParsers.parseSecretId(s) };
          case _ { null };
        };

        switch (secretIdOpt) {
          case (?secretId) {
            // Auth: Platform secrets require org-level; LLM keys allow workspace admin
            let requiredRoles : [SlackAuthMiddleware.AuthStep] = if (SecretModel.isPlatformSecret(secretId)) {
              [#IsPrimaryOwner, #IsOrgAdmin];
            } else {
              [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(workspaceId)];
            };
            switch (SlackAuthMiddleware.authorize(uac, requiredRoles)) {
              case (#err(msg)) {
                Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {
                switch (SecretModel.deleteSecret(secrets, workspaceId, secretId, { slackUserId = ?uac.slackUserId; agentId = null; operation = "delete-secret" })) {
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
          case (_) {
            Helpers.buildErrorResponse("Invalid secretId. Must be one of: openRouterApiKey, slackBotToken, slackSigningSecret, or custom:<name>");
          };
        };
      };
    };
  };
};
