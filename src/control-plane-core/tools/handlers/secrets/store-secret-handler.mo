import Json "mo:json";
import { str; obj; bool } "mo:json";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import SecretModel "../../../models/secret-model";
import KeyDerivationService "../../../services/key-derivation-service";
import WorkspaceModel "../../../models/workspace-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";
import SecretParsers "../parsers/secret-parsers";

module {
  /// Encrypt and store a secret for a workspace.
  ///
  /// JSON args: { workspaceId: number, secretId: string, secretValue: string }
  ///
  /// Authorization:
  ///   - Slack bot token (slackBotToken): requires #IsPrimaryOwner or #IsOrgAdmin
  ///   - LLM keys (openRouterApiKey): requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
    keyCache : KeyDerivationService.KeyCache,
    workspaces : WorkspaceModel.WorkspacesState,
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
        let secretIdOpt = switch (Json.get(json, "secretId")) {
          case (?#string(s)) { SecretParsers.parseSecretId(s) };
          case _ { null };
        };
        let secretValueOpt : ?Text = switch (Json.get(json, "secretValue")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };

        switch (wsIdOpt, secretIdOpt, secretValueOpt) {
          case (?wsId, ?secretId, ?secretValue) {
            // Auth: Platform secrets require org-level; LLM keys allow workspace admin
            let requiredRoles : [SlackAuthMiddleware.AuthStep] = if (SecretModel.isPlatformSecret(secretId)) {
              [#IsPrimaryOwner, #IsOrgAdmin];
            } else {
              [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(wsId)];
            };
            switch (SlackAuthMiddleware.authorize(uac, requiredRoles)) {
              case (#err(msg)) {
                return Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {};
            };

            // Platform secrets are org-level credentials; they must only
            // be stored on workspace 0. Allowing non-zero workspaces would be
            // meaningless (those workspaces never read these values).
            if (SecretModel.isPlatformSecret(secretId) and wsId != 0) {
              return Helpers.buildErrorResponse("Platform secrets (slackBotToken, slackSigningSecret) can only be set on workspace 0.");
            };

            // Validate secret is not empty
            if (Text.trim(secretValue, #char ' ') == "") {
              return Helpers.buildErrorResponse("Secret cannot be empty.");
            };

            // Verify workspace exists
            switch (Map.get(workspaces.workspaces, Nat.compare, wsId)) {
              case (null) {
                return Helpers.buildErrorResponse("Workspace not found.");
              };
              case (?_) {};
            };

            // Derive encryption key for this workspace
            let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, wsId);

            switch (SecretModel.storeSecret(secrets, encryptionKey, wsId, secretId, secretValue, { slackUserId = ?uac.slackUserId; agentId = null; operation = "store-secret" })) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Secret stored successfully.")),
                  ]),
                  null,
                );
              };
            };
          };
          case (null, _, _) {
            Helpers.buildErrorResponse("Missing required field: workspaceId");
          };
          case (_, null, _) {
            Helpers.buildErrorResponse("Invalid secretId. Must be one of: openRouterApiKey, slackSigningSecret, slackBotToken");
          };
          case (_, _, _) {
            Helpers.buildErrorResponse("Missing required field: secretValue");
          };
        };
      };
    };
  };
};
