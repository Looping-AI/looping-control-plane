import Json "mo:json";
import { str; obj; bool } "mo:json";
import McpToolRegistry "../../mcp-tool-registry";
import ToolTypes "../../tool-types";
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
        let serverId = switch (Json.get(json, "serverId")) {
          case (?#string(s)) { s };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: serverId");
          };
        };
        let description : ?Text = switch (Json.get(json, "description")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let parameters : ?Text = switch (Json.get(json, "parameters")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let remoteName : ?Text = switch (Json.get(json, "remoteName")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };

        let tool : ToolTypes.McpToolRegistration = {
          definition = {
            tool_type = "function";
            function = {
              name;
              description;
              parameters;
            };
          };
          serverId;
          remoteName;
        };

        switch (McpToolRegistry.register(registry, tool)) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("name", str(name)),
                ("message", str("MCP tool '" # name # "' registered successfully")),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
