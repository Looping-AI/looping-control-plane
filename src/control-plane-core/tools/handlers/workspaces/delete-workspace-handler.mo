import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Text "mo:core/Text";
import WorkspaceModel "../../../models/workspace-model";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    agentRegistry : ?AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    triggerMessageText : ?Text,
    args : Text,
  ) : Text {
    // Authorization: only org owners/admins may delete workspaces
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
            // Workspace 0 is protected — reject before any confirmation check
            if (wsId == 0) {
              return Helpers.buildErrorResponse("Workspace 0 (the org workspace) cannot be deleted.");
            };
            // Look up workspace to get its name for the confirmation check
            switch (WorkspaceModel.getWorkspace(state, wsId)) {
              case (null) {
                Helpers.buildErrorResponse("Workspace not found.");
              };
              case (?workspace) {
                let expectedPhrase = "::admin " # workspace.name;
                // Validate against the verbatim Slack message that triggered this turn.
                // This value is sourced directly from channel history — the LLM cannot
                // fabricate it. If the user has not typed the exact phrase, reject.
                switch (triggerMessageText) {
                  case (null) {
                    Helpers.buildErrorResponse(
                      "Confirmation could not be verified because the triggering message text was unavailable. " #
                      "The user must type exactly: " # expectedPhrase
                    );
                  };
                  case (?phrase) {
                    if (not Text.equal(phrase, expectedPhrase)) {
                      Helpers.buildErrorResponse(
                        "Confirmation phrase does not match. " #
                        "The user must type exactly: " # expectedPhrase
                      );
                    } else {
                      switch (WorkspaceModel.deleteWorkspace(state, wsId)) {
                        case (#err(msg)) { Helpers.buildErrorResponse(msg) };
                        case (#ok(())) {
                          // Also unregister the workspace's admin agent from the registry if present
                          switch (agentRegistry) {
                            case (?registry) {
                              switch (AgentModel.lookupAdminAgentByWorkspace(wsId, registry)) {
                                case (?adminAgent) {
                                  ignore AgentModel.unregisterById(adminAgent.id, registry);
                                };
                                case (null) {};
                              };
                            };
                            case (null) {
                              // No agent registry: skip agent cleanup, workspace is still deleted
                            };
                          };
                          Json.stringify(
                            obj([
                              ("success", bool(true)),
                              ("id", int(wsId)),
                              ("message", str("Workspace " # Nat.toText(wsId) # " deleted successfully")),
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
      };
    };
  };
};
