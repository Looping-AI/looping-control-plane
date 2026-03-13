import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Nat "mo:core/Nat";
import WorkspaceModel "../../../models/workspace-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
  ) : async Text {
    // Authorization: only org owners/admins may create workspaces
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        return Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {};
    };
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        switch (Json.get(json, "name")) {
          case (?#string(name)) {
            switch (WorkspaceModel.createWorkspace(state, name)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(wsId)) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("id", int(wsId)),
                    ("name", str(name)),
                    ("message", str("Workspace '" # name # "' created with ID " # Nat.toText(wsId))),
                  ]),
                  null,
                );
              };
            };
          };
          case _ { Helpers.buildErrorResponse("Missing required field: name") };
        };
      };
    };
  };
};
