import GroqWrapper "../wrappers/groq-wrapper";

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
