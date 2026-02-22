import { test; suite; expect } "mo:test";
import Text "mo:core/Text";
import InstructionComposer "../../../../src/open-org-backend/instructions/instruction-composer";
import InstructionTypes "../../../../src/open-org-backend/instructions/instruction-types";

// Helper to find position of substring (returns 0 if not found)
func findSubstringPosition(text : Text, pattern : Text) : Nat {
  let textChars = Text.toArray(text);
  let patternChars = Text.toArray(pattern);

  if (patternChars.size() == 0 or patternChars.size() > textChars.size()) {
    return 0;
  };

  label search for (i in textChars.keys()) {
    if (i + patternChars.size() > textChars.size()) {
      break search;
    };

    var matches = true;
    label check for (j in patternChars.keys()) {
      if (textChars[i + j] != patternChars[j]) {
        matches := false;
        break check;
      };
    };

    if (matches) {
      return i + 1; // Return 1-based position
    };
  };

  0;
};

suite(
  "InstructionComposer",
  func() {

    suite(
      "compose",
      func() {
        test(
          "includes constitution layer for any role",
          func() {
            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [],
              [],
            );

            // Should contain identity block from constitution
            expect.bool(Text.contains(result, #text("Looping AI"))).isTrue();
            // Should contain honesty block
            expect.bool(Text.contains(result, #text("If you don't know or can't perform a task"))).isTrue();
          },
        );

        test(
          "includes workspace admin role instructions",
          func() {
            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [],
              [],
            );

            expect.bool(Text.contains(result, #text("workspace administrator"))).isTrue();
          },
        );

        test(
          "includes workspace member role instructions",
          func() {
            let result = InstructionComposer.compose(
              #workspaceMember,
              [],
              [],
            );

            expect.bool(Text.contains(result, #text("workspace member"))).isTrue();
          },
        );

        test(
          "includes custom agent name",
          func() {
            let result = InstructionComposer.compose(
              #customAgent({ name = "TestBot"; persona = null }),
              [],
              [],
            );

            expect.bool(Text.contains(result, #text("You are TestBot."))).isTrue();
          },
        );

        test(
          "includes custom agent persona when provided",
          func() {
            let result = InstructionComposer.compose(
              #customAgent({
                name = "TestBot";
                persona = ?"You are friendly and helpful.";
              }),
              [],
              [],
            );

            expect.bool(Text.contains(result, #text("You are TestBot."))).isTrue();
            expect.bool(Text.contains(result, #text("friendly and helpful"))).isTrue();
          },
        );

        test(
          "includes context blocks for given contextIds",
          func() {
            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [#hasTools, #errorRecovery],
              [],
            );

            expect.bool(Text.contains(result, #text("access to tools"))).isTrue();
            expect.bool(Text.contains(result, #text("error"))).isTrue();
          },
        );

        test(
          "includes all context blocks when multiple provided",
          func() {
            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [#hasTools, #errorRecovery],
              [],
            );

            expect.bool(Text.contains(result, #text("access to tools"))).isTrue();
            expect.bool(Text.contains(result, #text("error"))).isTrue();
          },
        );

        test(
          "includes custom blocks at the end",
          func() {
            let customBlocks : [InstructionTypes.InstructionBlock] = [
              { id = "custom-1"; content = "CUSTOM_INSTRUCTION_ONE" },
              { id = "custom-2"; content = "CUSTOM_INSTRUCTION_TWO" },
            ];

            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [],
              customBlocks,
            );

            expect.bool(Text.contains(result, #text("CUSTOM_INSTRUCTION_ONE"))).isTrue();
            expect.bool(Text.contains(result, #text("CUSTOM_INSTRUCTION_TWO"))).isTrue();
          },
        );

        test(
          "separates blocks with double newlines",
          func() {
            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [],
              [],
            );

            // Should have double newlines between blocks
            expect.bool(Text.contains(result, #text("\n\n"))).isTrue();
          },
        );

        test(
          "works with empty contextIds and customBlocks",
          func() {
            let result = InstructionComposer.compose(
              #workspaceMember,
              [],
              [],
            );

            // Should still have constitution and role layers
            expect.bool(Text.contains(result, #text("Looping AI"))).isTrue();
            expect.bool(Text.contains(result, #text("workspace member"))).isTrue();
          },
        );

        test(
          "custom blocks appear after context blocks",
          func() {
            let customBlocks : [InstructionTypes.InstructionBlock] = [
              { id = "override"; content = "FINAL_OVERRIDE" },
            ];

            let result = InstructionComposer.compose(
              #workspaceAdmin,
              [#hasTools],
              customBlocks,
            );

            // Find positions to verify order
            let toolsPos = findSubstringPosition(result, "access to tools");
            let overridePos = findSubstringPosition(result, "FINAL_OVERRIDE");

            // Custom block should come after context block
            expect.bool(overridePos > toolsPos).isTrue();
          },
        );
      },
    );
  },
);
