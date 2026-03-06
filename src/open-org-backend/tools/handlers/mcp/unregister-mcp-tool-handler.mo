import Json "mo:json";
import { str; obj; bool } "mo:json";
import McpToolRegistry "../../mcp-tool-registry";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  public func handle(
    registry : McpToolRegistry.McpToolRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
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

        let removed = McpToolRegistry.unregister(registry, name);
        Json.stringify(
          obj([
            ("success", bool(true)),
            ("removed", bool(removed)),
            ("message", str(if removed { "MCP tool '" # name # "' unregistered successfully" } else { "MCP tool '" # name # "' was not found" })),
          ]),
          null,
        );
      };
    };
  };
};
