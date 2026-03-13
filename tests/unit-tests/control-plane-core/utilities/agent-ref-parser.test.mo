import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import AgentRefParser "../../../../src/control-plane-core/utilities/agent-ref-parser";
import AgentModel "../../../../src/control-plane-core/models/agent-model";

// ============================================
// Helpers
// ============================================

/// Register an agent with minimal config and return its ID (panics on error).
func registerSimple(
  state : AgentModel.AgentRegistryState,
  name : Text,
) : Nat {
  switch (
    AgentModel.register(
      name,
      0,
      #admin,
      #groq(#gpt_oss_120b),
      #api,
      [],
      [],
      [],
      Map.empty<Text, AgentModel.ToolState>(),
      [],
      state,
    )
  ) {
    case (#ok id) { id };
    case (#err e) { expect.text(e).equal("no error expected"); 0 };
  };
};

// ============================================
// Suite: parseReferences — basic matching
// ============================================

suite(
  "AgentRefParser - parseReferences — basic matching",
  func() {

    test(
      "empty string returns no references",
      func() {
        expect.nat(AgentRefParser.parseReferences("").size()).equal(0);
      },
    );

    test(
      "single ::agentname at start of message",
      func() {
        let refs = AgentRefParser.parseReferences("::my-agent hello");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("my-agent");
      },
    );

    test(
      "single ::agentname at end of message",
      func() {
        let refs = AgentRefParser.parseReferences("please ask ::helper");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("helper");
      },
    );

    test(
      "::agentname in the middle of a sentence",
      func() {
        let refs = AgentRefParser.parseReferences("hey ::planner can you help?");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("planner");
      },
    );

    test(
      "name with digits and hyphens is fully captured",
      func() {
        let refs = AgentRefParser.parseReferences("::agent-42-x");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent-42-x");
      },
    );

    test(
      "multiple distinct agents are all extracted in order",
      func() {
        let refs = AgentRefParser.parseReferences("::alpha and ::beta and ::gamma");
        expect.nat(refs.size()).equal(3);
        expect.text(refs[0]).equal("alpha");
        expect.text(refs[1]).equal("beta");
        expect.text(refs[2]).equal("gamma");
      },
    );

    test(
      "text with no :: returns no references",
      func() {
        expect.nat(AgentRefParser.parseReferences("just a normal message").size()).equal(0);
      },
    );

  },
);

// ============================================
// Suite: parseReferences — deduplication
// ============================================

suite(
  "AgentRefParser - parseReferences — deduplication",
  func() {

    test(
      "duplicate ::agentname is reported only once",
      func() {
        let refs = AgentRefParser.parseReferences("::bot and then again ::bot");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("bot");
      },
    );

    test(
      "same name appearing three times yields a single entry",
      func() {
        let refs = AgentRefParser.parseReferences("::a ::a ::a");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("a");
      },
    );

    test(
      "duplicate and unique names together are deduplicated correctly",
      func() {
        let refs = AgentRefParser.parseReferences("::x ::y ::x ::z ::y");
        expect.nat(refs.size()).equal(3);
        expect.text(refs[0]).equal("x");
        expect.text(refs[1]).equal("y");
        expect.text(refs[2]).equal("z");
      },
    );

  },
);

// ============================================
// Suite: parseReferences — escaped and word-prefixed references
// ============================================

suite(
  "AgentRefParser - parseReferences — escaping and word boundaries",
  func() {

    test(
      "\\::agentname (backslash-escaped) is ignored",
      func() {
        // The Motoko string "\\::bot" represents the literal text \::bot
        expect.nat(AgentRefParser.parseReferences("\\::bot").size()).equal(0);
      },
    );

    test(
      "word character immediately before :: suppresses the match",
      func() {
        // "foo::bar" — 'o' is a word char before `::`
        expect.nat(AgentRefParser.parseReferences("foo::bar").size()).equal(0);
      },
    );

    test(
      "digit immediately before :: suppresses the match",
      func() {
        expect.nat(AgentRefParser.parseReferences("1::bot").size()).equal(0);
      },
    );

    test(
      "underscore immediately before :: suppresses the match",
      func() {
        expect.nat(AgentRefParser.parseReferences("_::bot").size()).equal(0);
      },
    );

    test(
      "space before :: allows the match",
      func() {
        let refs = AgentRefParser.parseReferences("call ::scout now");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("scout");
      },
    );

    test(
      "newline before :: allows the match",
      func() {
        let refs = AgentRefParser.parseReferences("hey\n::bot");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("bot");
      },
    );

    test(
      "escaped reference mixed with real reference — only real is extracted",
      func() {
        let refs = AgentRefParser.parseReferences("\\::ghost but ::real is fine");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("real");
      },
    );

  },
);

// ============================================
// Suite: parseReferences — invalid name formats
// ============================================

suite(
  "AgentRefParser - parseReferences — invalid name formats",
  func() {

    test(
      ":: not followed by any character yields no reference",
      func() {
        expect.nat(AgentRefParser.parseReferences("::").size()).equal(0);
      },
    );

    test(
      ":: followed by a digit (not a-z) yields no reference",
      func() {
        expect.nat(AgentRefParser.parseReferences("::123bot").size()).equal(0);
      },
    );

    test(
      ":: followed by an uppercase letter yields no reference",
      func() {
        // Agent names must start with a-z; uppercase is rejected
        expect.nat(AgentRefParser.parseReferences("::Agent").size()).equal(0);
      },
    );

    test(
      ":: followed by a hyphen yields no reference",
      func() {
        expect.nat(AgentRefParser.parseReferences("::-agent").size()).equal(0);
      },
    );

    test(
      "name stops at the first non-name character",
      func() {
        // ::bot! — stops at '!'
        let refs = AgentRefParser.parseReferences("::bot!");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("bot");
      },
    );

    test(
      "name stops at space",
      func() {
        let refs = AgentRefParser.parseReferences("::hello world");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("hello");
      },
    );

  },
);

// ============================================
// Suite: parseReferences — inline code skipping
// ============================================

suite(
  "AgentRefParser - parseReferences — inline code skipping",
  func() {

    test(
      "::agent inside inline code is ignored",
      func() {
        expect.nat(AgentRefParser.parseReferences("`::hidden`").size()).equal(0);
      },
    );

    test(
      "::agent before inline code and a different one inside — only outer extracted",
      func() {
        let refs = AgentRefParser.parseReferences("::outer `::inner` rest");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("outer");
      },
    );

    test(
      "::agent after a closed inline code block is extracted",
      func() {
        let refs = AgentRefParser.parseReferences("`code` ::visible");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("visible");
      },
    );

    test(
      "multiple inline code spans skip their contents",
      func() {
        let refs = AgentRefParser.parseReferences("`::a` ::b `::c` ::d");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("b");
        expect.text(refs[1]).equal("d");
      },
    );

  },
);

// ============================================
// Suite: parseReferences — fenced code block skipping
// ============================================

suite(
  "AgentRefParser - parseReferences — fenced code block skipping",
  func() {

    test(
      "::agent inside a fenced code block is ignored",
      func() {
        let refs = AgentRefParser.parseReferences("```\n::hidden\n```");
        expect.nat(refs.size()).equal(0);
      },
    );

    test(
      "::agent before a fenced block and after are both extracted",
      func() {
        let refs = AgentRefParser.parseReferences("::before ```::skip``` ::after");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("before");
        expect.text(refs[1]).equal("after");
      },
    );

    test(
      "fenced block with multiple ::refs inside — all are ignored",
      func() {
        let refs = AgentRefParser.parseReferences("```\n::a\n::b\n::c\n```");
        expect.nat(refs.size()).equal(0);
      },
    );

    test(
      "fenced block followed by real reference",
      func() {
        let refs = AgentRefParser.parseReferences("```ignored``` then ::real");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("real");
      },
    );

    test(
      "fenced block with an inline tick in the middle",
      func() {
        let refs = AgentRefParser.parseReferences("````::ignored``` then ::foo ` ::middle ` ::bar ` ::last");
        expect.nat(refs.size()).equal(3);
        expect.text(refs[0]).equal("foo");
        expect.text(refs[1]).equal("bar");
        expect.text(refs[2]).equal("last");
      },
    );

  },
);

// ============================================
// Suite: parseReferences — unclosed delimiters
// ============================================

suite(
  "AgentRefParser - parseReferences — unclosed delimiters",
  func() {

    test(
      "unclosed single backtick does not suppress subsequent references",
      func() {
        let refs = AgentRefParser.parseReferences("` ::agent");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent");
      },
    );

    test(
      "unclosed backtick after a valid reference does not eat later refs",
      func() {
        let refs = AgentRefParser.parseReferences("::first ` ::second");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("first");
        expect.text(refs[1]).equal("second");
      },
    );

    test(
      "multiple unclosed backticks are all treated as literal",
      func() {
        let refs = AgentRefParser.parseReferences("` ` ` ::visible");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("visible");
      },
    );

    test(
      "unclosed fenced code block does not suppress subsequent references",
      func() {
        let refs = AgentRefParser.parseReferences("``` ::agent");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent");
      },
    );

    test(
      "unclosed fenced block after reference preserves both refs",
      func() {
        let refs = AgentRefParser.parseReferences("::first ``` ::second");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("first");
        expect.text(refs[1]).equal("second");
      },
    );

    test(
      "properly closed inline code still works alongside unclosed backtick",
      func() {
        // `::hidden` is inline code (properly closed), then ` is unclosed → literal
        let refs = AgentRefParser.parseReferences("`::hidden` ::visible ` ::also-visible");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("visible");
        expect.text(refs[1]).equal("also-visible");
      },
    );

    test(
      "properly closed fenced block still works alongside unclosed fenced block",
      func() {
        let refs = AgentRefParser.parseReferences("```::hidden``` ::visible ``` ::also-visible");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("visible");
        expect.text(refs[1]).equal("also-visible");
      },
    );

    test(
      "backtick immediately before :: does not suppress the reference",
      func() {
        // ` is not a word char, so `:: should still match
        let refs = AgentRefParser.parseReferences("`::agent");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent");
      },
    );

    test(
      "lone backtick in the middle of text is harmless",
      func() {
        let refs = AgentRefParser.parseReferences("::alpha ` ::beta");
        expect.nat(refs.size()).equal(2);
        expect.text(refs[0]).equal("alpha");
        expect.text(refs[1]).equal("beta");
      },
    );

    test(
      "odd number of backticks — last one is unclosed and literal",
      func() {
        // three separate inline code opportunities, but last ` has no pair
        let refs = AgentRefParser.parseReferences("`::a` `::b` ` ::c");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("c");
      },
    );

    test(
      "reference immediately after closing backtick is extracted",
      func() {
        let refs = AgentRefParser.parseReferences("`code`::agent");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent");
      },
    );

    test(
      "empty inline code does not break parsing",
      func() {
        let refs = AgentRefParser.parseReferences("`` ::agent");
        expect.nat(refs.size()).equal(1);
        expect.text(refs[0]).equal("agent");
      },
    );

  },
);

// ============================================
// Suite: extractValidAgents
// ============================================

suite(
  "AgentRefParser - extractValidAgents",
  func() {

    test(
      "known agent is returned",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "scout");
        let agents = AgentRefParser.extractValidAgents("::scout please search", state);
        expect.nat(agents.size()).equal(1);
        expect.text(agents[0].name).equal("scout");
      },
    );

    test(
      "unknown agent name is silently dropped",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "scout");
        let agents = AgentRefParser.extractValidAgents("::ghost do something", state);
        expect.nat(agents.size()).equal(0);
      },
    );

    test(
      "mix of known and unknown names — only known are returned",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "alpha");
        ignore registerSimple(state, "gamma");
        let agents = AgentRefParser.extractValidAgents("::alpha ::beta ::gamma", state);
        expect.nat(agents.size()).equal(2);
        expect.text(agents[0].name).equal("alpha");
        expect.text(agents[1].name).equal("gamma");
      },
    );

    test(
      "duplicate known name is returned only once",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "bot");
        let agents = AgentRefParser.extractValidAgents("::bot and ::bot again", state);
        expect.nat(agents.size()).equal(1);
        expect.text(agents[0].name).equal("bot");
      },
    );

    test(
      "registry lookup is case-insensitive (name stored lowercase, reference lowercase)",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "mybot");
        // Agent names are stored and parsed as lowercase; this confirms the round-trip
        let agents = AgentRefParser.extractValidAgents("::mybot", state);
        expect.nat(agents.size()).equal(1);
        expect.text(agents[0].name).equal("mybot");
      },
    );

    test(
      "no references in text returns empty result",
      func() {
        let state = AgentModel.emptyState();
        ignore registerSimple(state, "scout");
        let agents = AgentRefParser.extractValidAgents("just a plain message", state);
        expect.nat(agents.size()).equal(0);
      },
    );

    test(
      "empty registry returns no agents even when references are present",
      func() {
        let state = AgentModel.emptyState();
        let agents = AgentRefParser.extractValidAgents("::anyone out there?", state);
        expect.nat(agents.size()).equal(0);
      },
    );

  },
);
