import Json "mo:json";
import { str; obj; bool; arr } "mo:json";
import Array "mo:core/Array";
import McpToolRegistry "../../mcp-tool-registry";
import ToolTypes "../../tool-types";

module {
  private func toolToJson(t : ToolTypes.McpToolRegistration) : Json.Json {
    let fn = t.definition.function;
    let descJson : Json.Json = switch (fn.description) {
      case (?d) { str(d) };
      case (null) { #null_ };
    };
    let paramsJson : Json.Json = switch (fn.parameters) {
      case (?p) { str(p) };
      case (null) { #null_ };
    };
    let remoteNameJson : Json.Json = switch (t.remoteName) {
      case (?n) { str(n) };
      case (null) { #null_ };
    };
    obj([
      ("name", str(fn.name)),
      ("description", descJson),
      ("parameters", paramsJson),
      ("serverId", str(t.serverId)),
      ("remoteName", remoteNameJson),
    ]);
  };

  public func handle(
    registry : McpToolRegistry.McpToolRegistryState,
    _args : Text,
  ) : async Text {
    let tools = McpToolRegistry.getAll(registry);
    let items = Array.map<ToolTypes.McpToolRegistration, Json.Json>(tools, toolToJson);
    Json.stringify(
      obj([
        ("success", bool(true)),
        ("tools", arr(items)),
      ]),
      null,
    );
  };
};
