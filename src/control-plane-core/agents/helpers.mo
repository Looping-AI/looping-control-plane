import Text "mo:core/Text";
import AgentModel "../models/agent-model";
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

};
