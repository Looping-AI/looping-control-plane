import Array "mo:core/Array";
import Text "mo:core/Text";
import InstructionTypes "./instruction-types";
import ConstitutionLayer "./layers/constitution-layer";
import AgentRoleLayer "./layers/agent-role-layer";
import ContextLayer "./layers/context-layer";

module {
  /// Compose final instructions from all layers
  ///
  /// Layers are combined in order:
  /// 1. Constitution Layer - core principles (always included)
  /// 2. Agent Role Layer - role-specific instructions
  /// 3. Context Layer - dynamic constraints based on contextIds
  /// 4. Custom Layer - authoritative blocks from caller
  ///
  /// @param agentRole - Determines agent role layer blocks
  /// @param contextIds - Which context blocks to include (service decides)
  /// @param customBlocks - Custom layer blocks (authoritative, applied last)
  /// @returns Final instructions string
  public func compose(
    agentRole : InstructionTypes.AgentRole,
    contextIds : [InstructionTypes.ContextId],
    customBlocks : [InstructionTypes.InstructionBlock],
  ) : Text {
    // Build each layer
    let constitutionBlocks = ConstitutionLayer.getBlocks();
    let roleBlocks = AgentRoleLayer.getBlocks(agentRole);
    let contextBlocks = ContextLayer.getBlocks(contextIds);

    // Join blocks within each layer
    let constitutionText = joinBlocks(constitutionBlocks);
    let roleText = joinBlocks(roleBlocks);
    let contextText = joinBlocks(contextBlocks);
    let customText = joinBlocks(customBlocks);

    // Join all layers (skip empty layers)
    let allLayers = [constitutionText, roleText, contextText, customText];
    let nonEmptyLayers = Array.filter<Text>(
      allLayers,
      func(t : Text) : Bool { t != "" },
    );

    Text.join(nonEmptyLayers.vals(), "\n\n");
  };

  /// Join instruction blocks with double newlines
  private func joinBlocks(blocks : [InstructionTypes.InstructionBlock]) : Text {
    let contents = Array.map<InstructionTypes.InstructionBlock, Text>(
      blocks,
      func(b : InstructionTypes.InstructionBlock) : Text { b.content },
    );
    Text.join(contents.vals(), "\n\n");
  };
};
