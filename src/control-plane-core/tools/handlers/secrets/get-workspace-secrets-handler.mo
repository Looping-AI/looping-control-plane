import Json "mo:json";
import { obj; bool; arr } "mo:json";
import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import SecretModel "../../../models/secret-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Types "../../../types";
import Helpers "../handler-helpers";

module {
  /// List the secret identifiers stored for a workspace (values are never returned).
  ///
  /// JSON args: { workspaceId: number }
  ///
  /// Authorization: requires #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
  public func handle(
    secrets : SecretModel.SecretsState,
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

        switch (wsIdOpt) {
          case (null) {
            Helpers.buildErrorResponse("Missing required field: workspaceId");
          };
          case (?wsId) {
            switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(wsId)])) {
              case (#err(msg)) {
                Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {
                switch (SecretModel.getWorkspaceSecrets(secrets, wsId)) {
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
        };
      };
    };
  };

  /// Convert a SecretId variant to its string name.
  private func secretIdToString(id : Types.SecretId) : Text {
    switch (id) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#openaiApiKey) { "openaiApiKey" };
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
