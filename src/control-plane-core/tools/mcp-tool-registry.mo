import Map "mo:core/Map";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";

module {
  // ============================================
  // MCP Tool Registry
  // ============================================
  //
  // Dynamic registry of MCP tools.
  // Stored in state, configurable at runtime.
  // MCP execution is not yet implemented (stub).
  //
  // ============================================

  /// State type - store in main.mo as persistent
  public type McpToolRegistryState = Map.Map<Text, ToolTypes.McpToolRegistration>;

  /// Create empty registry
  public func empty() : McpToolRegistryState {
    Map.empty<Text, ToolTypes.McpToolRegistration>();
  };

  /// Register a new MCP tool
  /// Returns error if tool with same name already exists
  public func register(
    registry : McpToolRegistryState,
    tool : ToolTypes.McpToolRegistration,
  ) : { #ok; #err : Text } {
    let name = tool.definition.function.name;

    switch (Map.get(registry, Text.compare, name)) {
      case (?_) {
        #err("Tool with name '" # name # "' already exists");
      };
      case (null) {
        Map.add(registry, Text.compare, name, tool);
        #ok;
      };
    };
  };

  /// Unregister an MCP tool by name
  /// Returns true if tool was found and removed
  public func unregister(
    registry : McpToolRegistryState,
    name : Text,
  ) : Bool {
    switch (Map.get(registry, Text.compare, name)) {
      case (?_) {
        Map.remove(registry, Text.compare, name);
        true;
      };
      case (null) { false };
    };
  };

  /// Get all registered MCP tools
  public func getAll(registry : McpToolRegistryState) : [ToolTypes.McpToolRegistration] {
    let entries = Map.entries(registry);
    let values = Iter.map<(Text, ToolTypes.McpToolRegistration), ToolTypes.McpToolRegistration>(
      entries,
      func((_, v)) { v },
    );
    Iter.toArray(values);
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions(registry : McpToolRegistryState) : [OpenRouterWrapper.Tool] {
    Array.map<ToolTypes.McpToolRegistration, OpenRouterWrapper.Tool>(
      getAll(registry),
      func(t : ToolTypes.McpToolRegistration) : OpenRouterWrapper.Tool {
        t.definition;
      },
    );
  };

  /// Lookup an MCP tool by name
  public func get(
    registry : McpToolRegistryState,
    name : Text,
  ) : ?ToolTypes.McpToolRegistration {
    Map.get(registry, Text.compare, name);
  };
};
