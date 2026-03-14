import Array "mo:core/Array";
import Text "mo:core/Text";
import AgentModel "../models/agent-model";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import InstructionTypes "../instructions/instruction-types";

module {

  /// Map an AgentCategory to the appropriate AgentRole for instruction composition.
  ///
  ///   #admin         →  #orgAdmin
  ///   #research      →  #customAgent({ name; persona = ?"research specialist" })
  ///   #communication →  #customAgent({ name; persona = ?"communication specialist" })
  public func categoryToRole(
    category : AgentModel.AgentCategory,
    name : Text,
  ) : InstructionTypes.AgentRole {
    switch (category) {
      case (#admin) { #orgAdmin };
      case (#planning) {
        #customAgent({ name; persona = ?"work planning specialist" });
      };
      case (#research) {
        #customAgent({ name; persona = ?"research specialist" });
      };
      case (#communication) {
        #customAgent({ name; persona = ?"communication specialist" });
      };
    };
  };

  /// Return the filtered tool list after applying the agent's blocklists.
  ///
  /// Tools whose `definition.function.name` appears in either `toolsDisallowed`
  /// or `toolsMisconfigured` are removed. Unknown names in either list are
  /// silently ignored. This is the blocklist model: all resource-gated tools
  /// are enabled by default; admins selectively disable specific ones.
  public func applyToolBlocklist(
    agent : AgentModel.AgentRecord,
    tools : [OpenRouterWrapper.Tool],
  ) : [OpenRouterWrapper.Tool] {
    Array.filter<OpenRouterWrapper.Tool>(
      tools,
      func(tool : OpenRouterWrapper.Tool) : Bool {
        let name = tool.function.name;
        let isDisallowed = Array.any<Text>(
          agent.toolsDisallowed,
          func(t : Text) : Bool { t == name },
        );
        let isMisconfigured = Array.any<Text>(
          agent.toolsMisconfigured,
          func(t : Text) : Bool { t == name },
        );
        not isDisallowed and not isMisconfigured;
      },
    );
  };

  /// Return the `"agent-sources"` instruction block(s) for an agent.
  ///
  /// Returns a single-element array with the block when `agent.sources` is
  /// non-empty; returns `[]` when `agent.sources` is empty. The block lists
  /// each source on its own line, prefixed with `"- "`.
  public func sourceBlocks(
    agent : AgentModel.AgentRecord
  ) : [InstructionTypes.InstructionBlock] {
    if (agent.sources.size() == 0) {
      return [];
    };
    let sourcesText = Array.foldLeft<Text, Text>(
      agent.sources,
      "Knowledge Sources:\n",
      func(acc, src) { acc # "- " # src # "\n" },
    );
    [{ id = "agent-sources"; content = sourcesText }];
  };

};
