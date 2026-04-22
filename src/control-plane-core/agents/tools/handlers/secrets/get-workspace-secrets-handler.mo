import Json "mo:json";
import { obj; bool; arr } "mo:json";
import Array "mo:core/Array";
import SecretModel "../../../../models/secret-model";
import SlackAuthMiddleware "../../../../middleware/slack-auth-middleware";
import Types "../../../../types";
import Helpers "../handler-helpers";

module {
  /// List the secret identifiers stored for a workspace (values are never returned).
  ///
  /// `workspaceId` is caller-provided (not from JSON args) to enforce workspace
  /// scoping — the LLM cannot target a different workspace.
  ///
  /// Authorization: requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
    _args : Text,
  ) : async Text {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(workspaceId)])) {
      case (#err(msg)) {
        Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {
        switch (SecretModel.getWorkspaceSecrets(secrets, workspaceId)) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok(secretIds)) {
            let idStrings = secretIdArrayToJson(secretIds);
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("secretIds", arr(idStrings)),
              ]),
              null,
            );
          };
        };
      };
    };
  };

  /// Convert a SecretId variant to its string name.
  private func secretIdToString(id : Types.SecretId) : Text {
    switch (id) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#anthropicApiKey) { "anthropicApiKey" };
      case (#anthropicSetupToken) { "anthropicSetupToken" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
      case (#custom(name)) { "custom:" # name };
    };
  };

  private func secretIdArrayToJson(ids : [Types.SecretId]) : [Json.Json] {
    Array.map<Types.SecretId, Json.Json>(
      ids,
      func(id : Types.SecretId) : Json.Json {
        #string(secretIdToString(id));
      },
    );
  };
};
