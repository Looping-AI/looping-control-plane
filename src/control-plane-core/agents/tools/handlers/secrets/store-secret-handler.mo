import Json "mo:json";
import { str; obj; bool } "mo:json";
import Text "mo:core/Text";
import SecretModel "../../../../models/secret-model";
import WorkspaceModel "../../../../models/workspace-model";
import SlackAuthMiddleware "../../../../middleware/slack-auth-middleware";
import ToolTypes "../../tool-types";
import SecretParsers "../parsers/secret-parsers";

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
        #error("Failed to parse arguments: " # debug_show error);
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
                return #error("Unauthorized: " # msg);
              };
              case (#ok(())) {};
            };

            // Platform secrets are org-level credentials; they must only
            // be stored on the org workspace. Allowing non-zero workspaces would be
            // meaningless (those workspaces never read these values).
            if (SecretModel.isPlatformSecret(secretId) and not WorkspaceModel.isOrgWorkspace(workspaceId)) {
              return #error("Platform secrets (slackBotToken, slackSigningSecret) can only be set on workspace 0.");
            };

            // Validate secret is not empty
            if (Text.trim(secretValue, #char ' ') == "") {
              return #error("Secret cannot be empty.");
            };

            switch (SecretModel.storeSecret(secrets, workspaceKey, workspaceId, secretId, secretValue, { slackUserId = ?uac.slackUserId; agentId = null; operation = "store-secret" })) {
              case (#err(msg)) { #error(msg) };
              case (#ok(())) {
                #success(
                  Json.stringify(
                    obj([
                      ("success", bool(true)),
                      ("message", str("Secret stored successfully.")),
                    ]),
                    null,
                  )
                );
              };
            };
          };
          case (null, _) {
            #error("Invalid secretId. Must be one of: openRouterApiKey, slackSigningSecret, slackBotToken");
          };
          case (_, _) {
            #error("Missing required field: secretValue");
          };
        };
      };
    };
  };
};
