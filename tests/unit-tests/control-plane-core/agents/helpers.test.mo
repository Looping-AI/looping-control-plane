import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import InstructionComposer "../../../../src/control-plane-core/instructions/instruction-composer";
import AgentHelpers "../../../../src/control-plane-core/agents/helpers";
import AgentModel "../../../../src/control-plane-core/models/agent-model";
import OpenRouterWrapper "../../../../src/control-plane-core/wrappers/openrouter-wrapper";

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Minimal AgentRecord with the given blocklists and sources.
func makeAgent(
  category : AgentModel.AgentCategory,
  name : Text,
  toolsDisallowed : [Text],
  toolsMisconfigured : [Text],
  sources : [Text],
) : AgentModel.AgentRecord {
  {
    id = 0;
    name;
    workspaceId = 0;
    category;
    llmModel = #openRouter(#gpt_oss_120b);
    executionType = #api;
    secretsAllowed = [];
    toolsDisallowed;
    toolsMisconfigured;
    toolsState = Map.empty<Text, AgentModel.ToolState>();
    sources;
  };
};

/// Build a minimal OpenRouterWrapper.Tool with only a name.
func makeTool(name : Text) : OpenRouterWrapper.Tool {
  {
    tool_type = "function";
    function = { name; description = null; parameters = null };
  };
};

/// Check whether a tool with the given name exists in the slice.
func toolExists(tools : [OpenRouterWrapper.Tool], name : Text) : Bool {
  var found = false;
  for (t in tools.vals()) {
    if (t.function.name == name) { found := true };
  };
  found;
};

// ═══════════════════════════════════════════════════════════════════════════════
// categoryToRole
// ═══════════════════════════════════════════════════════════════════════════════

suite(
  "AgentHelpers - categoryToRole",
  func() {

    test(
      "#admin maps to #orgAdmin and produces org admin persona text",
      func() {
        let role = AgentHelpers.categoryToRole(#admin, "my-admin");
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
      "#research maps to #customAgent with 'research specialist' persona",
      func() {
        let role = AgentHelpers.categoryToRole(#research, "my-research");
        let persona = switch (role) {
          case (#customAgent(a)) { a.persona };
          case (_) { null };
        };
        let isResearch = switch (persona) {
          case (?"research specialist") { true };
          case (_) { false };
        };
        expect.bool(isResearch).isTrue();

        let instructions = InstructionComposer.compose(role, [], []);
        expect.bool(Text.contains(instructions, #text("research specialist"))).isTrue();
      },
    );

    test(
      "#communication maps to #customAgent with 'communication specialist' persona",
      func() {
        let role = AgentHelpers.categoryToRole(#communication, "my-comm");
        let persona = switch (role) {
          case (#customAgent(a)) { a.persona };
          case (_) { null };
        };
        let isComm = switch (persona) {
          case (?"communication specialist") { true };
          case (_) { false };
        };
        expect.bool(isComm).isTrue();

        let instructions = InstructionComposer.compose(role, [], []);
        expect.bool(Text.contains(instructions, #text("communication specialist"))).isTrue();
      },
    );
  },
);

// ═══════════════════════════════════════════════════════════════════════════════
// applyToolBlocklist
// ═══════════════════════════════════════════════════════════════════════════════

suite(
  "AgentHelpers - applyToolBlocklist - empty blocklists",
  func() {

    test(
      "all tools pass through when both blocklists are empty",
      func() {
        let agent = makeAgent(#admin, "a", [], [], []);
        let tools = [makeTool("echo"), makeTool("web_search"), makeTool("save_value_stream")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(3);
      },
    );

    test(
      "returns empty array when input tools are empty",
      func() {
        let agent = makeAgent(#admin, "a", [], [], []);
        let result = AgentHelpers.applyToolBlocklist(agent, []);
        expect.nat(result.size()).equal(0);
      },
    );
  },
);

suite(
  "AgentHelpers - applyToolBlocklist - toolsDisallowed",
  func() {

    test(
      "removes the disallowed tool from the list",
      func() {
        let agent = makeAgent(#admin, "a", ["web_search"], [], []);
        let tools = [makeTool("echo"), makeTool("web_search"), makeTool("save_value_stream")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(2);
        expect.bool(toolExists(result, "web_search")).isFalse();
        expect.bool(toolExists(result, "echo")).isTrue();
        expect.bool(toolExists(result, "save_value_stream")).isTrue();
      },
    );

    test(
      "removes multiple disallowed tools",
      func() {
        let agent = makeAgent(#admin, "a", ["echo", "web_search"], [], []);
        let tools = [makeTool("echo"), makeTool("web_search"), makeTool("save_value_stream")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(1);
        expect.text(result[0].function.name).equal("save_value_stream");
      },
    );
  },
);

suite(
  "AgentHelpers - applyToolBlocklist - toolsMisconfigured",
  func() {

    test(
      "removes a misconfigured tool even when it is not in toolsDisallowed",
      func() {
        let agent = makeAgent(#admin, "a", [], ["stripe-api"], []);
        let tools = [makeTool("echo"), makeTool("stripe-api")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(1);
        expect.text(result[0].function.name).equal("echo");
      },
    );
  },
);

suite(
  "AgentHelpers - applyToolBlocklist - combined blocklists",
  func() {

    test(
      "removes tools from both disallowed and misconfigured lists",
      func() {
        let agent = makeAgent(#admin, "a", ["web_search"], ["stripe-api"], []);
        let tools = [makeTool("echo"), makeTool("web_search"), makeTool("stripe-api")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(1);
        expect.text(result[0].function.name).equal("echo");
      },
    );
  },
);

suite(
  "AgentHelpers - applyToolBlocklist - unknown tool names",
  func() {

    test(
      "ignores unknown names in toolsDisallowed without panicking",
      func() {
        let agent = makeAgent(#admin, "a", ["nonexistent-tool", "also-fake"], [], []);
        let tools = [makeTool("echo"), makeTool("web_search")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        // All tools are still present — unknown names in the blocklist are silently ignored
        expect.nat(result.size()).equal(2);
      },
    );

    test(
      "ignores unknown names in toolsMisconfigured without panicking",
      func() {
        let agent = makeAgent(#admin, "a", [], ["nonexistent-tool"], []);
        let tools = [makeTool("echo")];
        let result = AgentHelpers.applyToolBlocklist(agent, tools);
        expect.nat(result.size()).equal(1);
      },
    );
  },
);

// ═══════════════════════════════════════════════════════════════════════════════
// sourceBlocks
// ═══════════════════════════════════════════════════════════════════════════════

suite(
  "AgentHelpers - sourceBlocks",
  func() {

    test(
      "returns a single 'agent-sources' block when sources are non-empty",
      func() {
        let agent = makeAgent(#admin, "a", [], [], ["https://docs.example.com", "https://other.com"]);
        let blocks = AgentHelpers.sourceBlocks(agent);
        expect.nat(blocks.size()).equal(1);
        expect.text(blocks[0].id).equal("agent-sources");
        expect.bool(Text.contains(blocks[0].content, #text("https://docs.example.com"))).isTrue();
        expect.bool(Text.contains(blocks[0].content, #text("https://other.com"))).isTrue();
      },
    );

    test(
      "each source appears on its own line prefixed with '- '",
      func() {
        let agent = makeAgent(#admin, "a", [], [], ["https://docs.example.com"]);
        let blocks = AgentHelpers.sourceBlocks(agent);
        expect.bool(Text.contains(blocks[0].content, #text("- https://docs.example.com"))).isTrue();
      },
    );

    test(
      "returns empty array when sources list is empty",
      func() {
        let agent = makeAgent(#admin, "a", [], [], []);
        let blocks = AgentHelpers.sourceBlocks(agent);
        expect.nat(blocks.size()).equal(0);
      },
    );
  },
);
