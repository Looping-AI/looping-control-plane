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
    };
  };
};
