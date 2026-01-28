import List "mo:core/List";
import InstructionTypes "../instruction-types";

module {
  /// Get agent role layer blocks based on the role
  public func getBlocks(role : InstructionTypes.AgentRole) : [InstructionTypes.InstructionBlock] {
    switch (role) {
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
        let blocks = List.empty<InstructionTypes.InstructionBlock>();

        List.add(
          blocks,
          {
            id = "agent-name";
            content = "You are " # agent.name # ".";
          },
        );

        switch (agent.persona) {
          case (?persona) {
            List.add(
              blocks,
              {
                id = "agent-persona";
                content = persona;
              },
            );
          };
          case (null) {};
        };

        List.toArray(blocks);
      };
    };
  };
};
