import { test; suite; expect } "mo:test";
import Text "mo:core/Text";
import InstructionComposer "../../../../src/control-plane-core/agents/instructions/instruction-composer";
import AgentHelpers "../../../../src/control-plane-core/agents/helpers";

// ═══════════════════════════════════════════════════════════════════════════════
// categoryToRole
// ═══════════════════════════════════════════════════════════════════════════════

suite(
  "AgentHelpers - categoryToRole",
  func() {

    test(
      "#_system(#admin) maps to #orgAdmin and produces org admin persona text",
      func() {
        let role = AgentHelpers.categoryToRole(#_system(#admin), "my-admin");
        let isOrgAdmin = switch (role) {
          case (#orgAdmin) { true };
          case (_) { false };
        };
        expect.bool(isOrgAdmin).isTrue();

        // Composing with #orgAdmin must produce the org-admin-role text
        let instructions = InstructionComposer.compose(role, [], []);
        expect.bool(Text.contains(instructions, #text("organizational admin assistant"))).isTrue();
      },
    );

    test(
      "#_system(#onboarding) maps to #customAgent with no persona",
      func() {
        let role = AgentHelpers.categoryToRole(#_system(#onboarding), "my-onboarding");
        let isCustom = switch (role) {
          case (#customAgent(_)) { true };
          case (_) { false };
        };
        expect.bool(isCustom).isTrue();

        let instructions = InstructionComposer.compose(role, [], []);
        expect.bool(Text.contains(instructions, #text("my-onboarding"))).isTrue();
      },
    );

    test(
      "#custom maps to #customAgent with no persona",
      func() {
        let role = AgentHelpers.categoryToRole(#custom, "my-custom");
        let isCustom = switch (role) {
          case (#customAgent(_)) { true };
          case (_) { false };
        };
        expect.bool(isCustom).isTrue();

        let instructions = InstructionComposer.compose(role, [], []);
        expect.bool(Text.contains(instructions, #text("my-custom"))).isTrue();
      },
    );
  },
);
