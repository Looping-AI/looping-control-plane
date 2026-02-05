import GroqWrapper "../wrappers/groq-wrapper";
import ValueStreamModel "../models/value-stream-model";
import MetricModel "../models/metric-model";

module {
  // ============================================
  // Shared Tool Types
  // ============================================

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
  };

  /// Outcome of a tool call execution
  public type ToolCallOutcome = {
    #success : Text; // JSON string result
    #error : Text; // Error message
  };

  // ============================================
  // Function Tool Resources
  // ============================================

  /// Resources that can be provided to function tools.
  /// Each resource is optional - tools requiring unavailable resources are excluded.
  /// This creates a natural allowlist mechanism controlled by the caller.
  public type ToolResources = {
    // Current workspace context
    workspaceId : ?Nat;

    // Groq API key - required for web search and other Groq-powered tools
    groqApiKey : ?Text;

    // Value Streams - if provided with write=true, save_value_stream tool is available
    valueStreams : ?{
      map : ValueStreamModel.ValueStreamsMap;
      write : Bool; // false = read-only (future: could enable a "get_value_streams" tool)
    };

    // Metrics - if provided with write=true, metric management tools are available
    metrics : ?{
      registryState : MetricModel.MetricsRegistryState;
      datapoints : MetricModel.MetricDatapointsStore;
      write : Bool; // false = read-only (future: could enable read-only metric tools)
    };

    // Future resources:
    // objectives : ?{ map : ObjectiveModel.WorkspaceObjectivesMap; write : Bool };
  };

  // ============================================
  // MCP Tool Types
  // ============================================

  /// MCP tool registration - stored in state, runtime configurable
  public type McpToolRegistration = {
    definition : GroqWrapper.Tool;
    serverId : Text; // Reference to MCP server config
    remoteName : ?Text; // Tool name on server (if different from definition.function.name)
  };

  /// MCP server configuration
  public type McpServerConfig = {
    id : Text;
    endpoint : Text;
    // Future: auth config, headers, etc.
  };
};
