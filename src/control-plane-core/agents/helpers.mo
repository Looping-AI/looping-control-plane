import Text "mo:core/Text";
import AgentModel "../models/agent-model";
import ExecutionTypes "../types/execution";
import InstructionTypes "./instructions/instruction-types";

module {

  /// Map an AgentCategory to the appropriate AgentRole for instruction composition.
  ///
  ///   #_system(#admin)      →  #orgAdmin
  ///   #_system(#onboarding) →  #customAgent({ name; persona = null })
  ///   #custom              →  #customAgent({ name; persona = null })
  public func categoryToRole(
    category : AgentModel.AgentCategory,
    name : Text,
  ) : InstructionTypes.AgentRole {
    switch (category) {
      case (#_system(#admin)) { #orgAdmin };
      case (#_system(#onboarding)) {
        #customAgent({ name; persona = null });
      };
      case (#custom) {
        #customAgent({ name; persona = null });
      };
    };
  };

  /// Build scope grants based on agent category and ownership.
  ///
  ///   #_system(#admin) + org workspace (ownedBy=0) → 4 write grants (workspace, agents, slackQueue, session)
  ///   #_system(#admin) + other workspace           → 3 grants (workspace read, agents write, session write)
  ///   #_system(#onboarding) or #custom             → 1 per-agent read grant
  public func buildScopeGrants(agent : AgentModel.AgentRecord) : [ExecutionTypes.ScopeGrant] {
    switch (agent.category) {
      case (#_system(#admin)) {
        if (AgentModel.isOrgAdmin(agent)) {
          [
            #workspace({ access = #write }),
            #agents({ access = #write }),
            #slackQueue({ access = #write }),
            #session({ access = #write }),
          ];
        } else {
          [
            #workspace({ access = #read }),
            #agents({ access = #write }),
            #session({ access = #write }),
          ];
        };
      };
      case (#_system(#onboarding) or #custom) {
        [#agent({ id = agent.id; access = #read })];
      };
    };
  };

};
