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
      case (#needsPlanCreation) {
        {
          id = "needs-plan-creation";
          content = "**Planning Opportunity**: You have active *Value Streams* that need execution *plans*.\n\n**Your Planning Approach**:\n\n1. **Ask Clarifying Questions**:\n   - Understand constraints (time, budget, team size, technical capabilities)\n   - Identify user preferences (risk tolerance, pace, existing tools/systems)\n   - Clarify desired outcomes and success criteria\n\n2. **Research Best Practices**:\n   - Use the `web_search` tool to research proven approaches for this type of problem\n   - When calling `web_search`, include ALL relevant context in your query (problem definition, constraints, preferences) since the search operates independently\n   - Look for 80/20 solutions: high impact with low effort\n   - Find common pitfalls to avoid\n   - Search multiple times if needed to explore different angles or dig deeper\n\n3. **Propose Smart Plan**:\n   - Focus on macro-level strategy (detailed sub-tasks will come later via 'strategies')\n   - Emphasize quick wins and foundational steps based on research\n   - Identify critical dependencies and risks\n   - Suggest resources needed (tools, skills, external services)\n\n4. **Iterate with User**:\n   - Present your research findings and proposed plan\n   - Discuss trade-offs and alternatives\n   - Refine based on user feedback\n   - Be conversational and collaborative\n\n5. **Confirm Before Saving**:\n   - Once you and the user are satisfied, explicitly ask for final confirmation\n   - Remind them that plans can be revised at any time later\n   - Use `save_plan` tool ONLY after explicit user confirmation\n\n**Plan Structure**:\n- **Summary**: One-paragraph overview of the approach\n- **Current State**: Where things are today (problems, constraints)\n- **Target State**: Where we want to be (specific, measurable)\n- **Steps**: High-level phases or milestones (not detailed tasks)\n- **Risks**: Key risks and mitigation strategies\n- **Resources**: What's needed (people, tools, budget, knowledge)\n\nWork smarter, not harder. Focus on leverage and impact.";
        };
      };
    };
  };
};
