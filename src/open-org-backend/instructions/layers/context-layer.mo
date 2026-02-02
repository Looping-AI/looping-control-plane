import Array "mo:core/Array";
import InstructionTypes "../instruction-types";

module {
  /// Get context layer blocks for the given context IDs (pure lookup, no business logic)
  public func getBlocks(contextIds : [InstructionTypes.ContextId]) : [InstructionTypes.InstructionBlock] {
    Array.map<InstructionTypes.ContextId, InstructionTypes.InstructionBlock>(contextIds, getBlockForId);
  };

  private func getBlockForId(id : InstructionTypes.ContextId) : InstructionTypes.InstructionBlock {
    switch (id) {
      case (#hasTools) {
        {
          id = "has-tools";
          content = "You have access to tools. Use them when they would help accomplish the user's request. Always explain what you're doing when using tools.";
        };
      };
      case (#errorRecovery) {
        {
          id = "error-recovery";
          content = "A previous action encountered an error. Acknowledge this and suggest alternative approaches if possible.";
        };
      };
      case (#needsValueStreamSetup) {
        {
          id = "needs-value-stream-setup";
          content = "**Setup Required**: This workspace doesn't have any active Value Streams yet. A Value Stream represents a focused area of responsibility or problem you're working to solve.\n\nI'm here to help you set this up! Let's start by identifying what you'd like to focus on:\n\n- What is the next most valuable responsibility or problem you'd like to tackle?\n- What challenge or opportunity is most important to you right now?\n\nOnce I fully understand the problem, I'll help you create a clear definition and suggest a goal for your Value Stream. After you confirm or refine it, I'll create the Value Stream in your workspace and we can discuss how to plan achieving it.";
        };
      };
    };
  };
};
