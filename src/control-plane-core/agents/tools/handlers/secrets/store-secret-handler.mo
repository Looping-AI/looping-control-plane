import Json "mo:json";
import { str; obj } "mo:json";
import Text "mo:core/Text";
import SecretModel "../../../../models/secret-model";
import WorkspaceModel "../../../../models/workspace-model";
import SlackAuthMiddleware "../../../../middleware/slack-auth-middleware";
import ToolTypes "../../tool-types";
import SecretParsers "../parsers/secret-parsers";
import HandlerHelpers "../handler-helpers";

module {
  /// Encrypt and store a secret for a workspace.
  ///
  /// `workspaceId` is caller-provided (not from JSON args) to enforce workspace
  /// scoping — the LLM cannot target a different workspace.
  ///
  /// JSON args: { secretId: string, secretValue: string }
  ///
  /// Authorization:
  ///   - Slack bot token (slackBotToken): requires #IsPrimaryOwner or #IsOrgAdmin
  ///   - LLM keys (openRouterApiKey): requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
    workspaceKey : [Nat8],
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
    args : Text,
  ) : ToolTypes.ToolCallOutcome {
    switch (Json.parse(args)) {
      case (#err(error)) {
        HandlerHelpers.makeError("parseError", "Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let secretIdOpt = switch (Json.get(json, "secretId")) {
          case (?#string(s)) { SecretParsers.parseSecretId(s) };
          case _ { null };
        };
        let secretValueOpt : ?Text = switch (Json.get(json, "secretValue")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };

        switch (secretIdOpt, secretValueOpt) {
          case (?secretId, ?secretValue) {
            // Auth: Platform secrets require org-level; LLM keys allow workspace admin
            let requiredRoles : [SlackAuthMiddleware.AuthStep] = if (SecretModel.isPlatformSecret(secretId)) {
              [#IsPrimaryOwner, #IsOrgAdmin];
            } else {
              [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(workspaceId)];
            };
            switch (SlackAuthMiddleware.authorize(uac, requiredRoles)) {
              case (#err(msg)) {
                return HandlerHelpers.makeError("unauthorized", "Unauthorized: " # msg);
              };
              case (#ok(())) {};
            };

            // Platform secrets are org-level credentials; they must only
            // be stored on the org workspace. Allowing non-zero workspaces would be
            // meaningless (those workspaces never read these values).
            if (SecretModel.isPlatformSecret(secretId) and not WorkspaceModel.isOrgWorkspace(workspaceId)) {
              return HandlerHelpers.makeError("forbidden", "Platform secrets (slackBotToken, slackSigningSecret) can only be set on workspace 0.");
            };

            // Validate secret is not empty
            if (Text.trim(secretValue, #char ' ') == "") {
              return HandlerHelpers.makeError("emptyValue", "Secret cannot be empty.");
            };

            switch (SecretModel.storeSecret(secrets, workspaceKey, workspaceId, secretId, secretValue, { slackUserId = ?uac.slackUserId; agentId = null; operation = "store-secret" })) {
              case (#err(msg)) {
                HandlerHelpers.makeError("operationFailed", msg);
              };
              case (#ok(())) {
                #ok(
                  Json.stringify(
                    obj([
                      ("message", str("Secret stored successfully.")),
                    ]),
                    null,
                  )
                );
              };
            };
          };
          case (null, _) {
            HandlerHelpers.makeError("invalidSecretId", "Invalid secretId. Must be one of: openRouterApiKey, slackSigningSecret, slackBotToken");
          };
          case (_, _) {
            HandlerHelpers.makeError("missingField", "Missing required field: secretValue");
          };
        };
      };
    };
  };
};
