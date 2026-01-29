import Array "mo:core/Array";
import GroqWrapper "../wrappers/groq-wrapper";

module {
  // ============================================
  // Function Tool Registry
  // ============================================
  //
  // Static registry of function tools.
  // Each tool has its definition (what LLM sees) and handler (implementation).
  // To add a new tool: add it to getAll() with definition + handler.
  //
  // ============================================

  /// A function tool with definition and implementation
  public type FunctionTool = {
    definition : GroqWrapper.Tool;
    handler : (Text) -> async Text;
  };

  /// Get all registered function tools
  public func getAll() : [FunctionTool] {
    [
      // ==========================================
      // ECHO TOOL (for testing)
      // ==========================================
      {
        definition = {
          tool_type = "function";
          function = {
            name = "echo";
            description = ?"Echoes back the input message. Useful for testing.";
            parameters = ?"{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"The message to echo back\"}},\"required\":[\"message\"]}";
          };
        };
        handler = func(args : Text) : async Text {
          // Simply return the arguments as-is
          args;
        };
      },

      // ==========================================
      // ADD NEW FUNCTION TOOLS BELOW
      // ==========================================
      // Example:
      // {
      //   definition = {
      //     tool_type = "function";
      //     function = {
      //       name = "my_tool";
      //       description = ?"Description for LLM";
      //       parameters = ?"{...JSON schema...}";
      //     };
      //   };
      //   handler = func(args : Text) : async Text {
      //     // Implementation here
      //   };
      // },
    ];
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions() : [GroqWrapper.Tool] {
    Array.map<FunctionTool, GroqWrapper.Tool>(
      getAll(),
      func(t : FunctionTool) : GroqWrapper.Tool { t.definition },
    );
  };

  /// Lookup a function tool by name
  public func get(name : Text) : ?FunctionTool {
    Array.find<FunctionTool>(
      getAll(),
      func(t : FunctionTool) : Bool {
        t.definition.function.name == name;
      },
    );
  };
};
