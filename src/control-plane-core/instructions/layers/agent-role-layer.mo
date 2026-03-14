import InstructionTypes "../instruction-types";

module {
  /// Get agent role layer blocks based on the role
  public func getBlocks(role : InstructionTypes.AgentRole) : [InstructionTypes.InstructionBlock] {
    switch (role) {
      case (#orgAdmin) {
        [
          {
            id = "org-admin-role";
            content = "You are an organizational admin assistant. Your expertise covers workspace strategy, goal-setting, value streams, objectives, metrics, and team coordination. Help users manage and improve their organization.";
          },
        ];
      };
      case (#workspaceAdmin) {
        [
          {
            id = "admin-role";
            content = "You are assisting a workspace administrator. They have full permissions to manage agents, members, and workspace settings.";
          },
        ];
      };
      case (#workspaceMember) {
        [
          {
            id = "member-role";
            content = "You are assisting a workspace member. They can interact with agents but don't have administrative permissions.";
          },
        ];
      };
      case (#customAgent(agent)) {
        // Produce a single combined persona block:
        // "You are {name}, a {persona ?? "general-purpose"} AI assistant."
        let persona = switch (agent.persona) {
          case (?p) { p };
          case (null) { "general-purpose" };
        };
        [
          {
            id = "agent-persona";
            content = "You are " # agent.name # ", a " # persona # " AI assistant.";
          },
        ];
      };
    };
  };
};
