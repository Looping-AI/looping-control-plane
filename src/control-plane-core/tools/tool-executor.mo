import List "mo:core/List";
import Error "mo:core/Error";
import GroqWrapper "../wrappers/groq-wrapper";
import ToolTypes "./tool-types";
import FunctionToolRegistry "./function-tool-registry";
import McpToolRegistry "./mcp-tool-registry";

module {
  // ============================================
  // Tool Executor
  // ============================================
  //
  // Executes tool calls returned by the LLM.
  // Routes to the appropriate registry based on tool type:
  // - Function tools: calls handler directly
  // - MCP tools: calls MCP server (not yet implemented)
  //
  // ============================================

  /// Execute all tool calls from an LLM response
  /// Returns results for each call in the same order
  public func execute(
    resources : ToolTypes.ToolResources,
    mcpRegistry : McpToolRegistry.McpToolRegistryState,
    toolCalls : [GroqWrapper.ToolCall],
  ) : async [ToolTypes.ToolResult] {
    let results = List.empty<ToolTypes.ToolResult>();

    for (call in toolCalls.vals()) {
      let result = await executeOne(resources, mcpRegistry, call);
      List.add(results, result);
    };

    List.toArray(results);
  };

  /// Execute a single tool call
  private func executeOne(
    resources : ToolTypes.ToolResources,
    mcpRegistry : McpToolRegistry.McpToolRegistryState,
    call : GroqWrapper.ToolCall,
  ) : async ToolTypes.ToolResult {
    // First, check function tools (static registry)
    switch (FunctionToolRegistry.get(resources, call.toolName)) {
      case (?tool) {
        try {
          let output = await tool.handler(call.arguments);
          {
            callId = call.callId;
            result = #success(output);
          };
        } catch (e : Error) {
          {
            callId = call.callId;
            result = #error("Handler error: " # Error.message(e));
          };
        };
      };
      case (null) {
        // Check MCP tools (dynamic registry)
        switch (McpToolRegistry.get(mcpRegistry, call.toolName)) {
          case (?mcpTool) {
            // MCP execution not yet implemented
            {
              callId = call.callId;
              result = #error("MCP tool execution not yet implemented. Server: " # mcpTool.serverId);
            };
          };
          case (null) {
            // Unknown tool
            {
              callId = call.callId;
              result = #error("Unknown tool: " # call.toolName);
            };
          };
        };
      };
    };
  };

  /// Format tool results as input for the next LLM turn
  /// Uses a structured format the LLM can understand
  public func formatResultsForLlm(results : [ToolTypes.ToolResult]) : Text {
    var output = "";
    for (result in results.vals()) {
      output #= "Tool call " # result.callId # " result:\n";
      switch (result.result) {
        case (#success(data)) {
          output #= data # "\n\n";
        };
        case (#error(err)) {
          output #= "Error: " # err # "\n\n";
        };
      };
    };
    output;
  };
};
