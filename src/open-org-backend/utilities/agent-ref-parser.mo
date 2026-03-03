/// Agent Reference Parser
/// Parses `::agentname` references from Slack message text.
///
/// Syntax rules (equivalent to the regex `(?<!\\)(?<!\w)::([a-z][a-z0-9-]*)`):
///   - `::name` must not be immediately preceded by a word character (`[a-zA-Z0-9_]`).
///   - `::name` must not be immediately preceded by a backslash (`\::name` is escaped).
///   - `name` must start with a lowercase letter followed by zero or more `[a-z0-9-]` chars.
///   - References inside inline code (`` `...` ``) are ignored.
///   - References inside fenced code blocks (` ```...``` `) are ignored.
///
/// This module provides two public functions:
///   - `parseReferences(text)` — returns raw lowercase name strings, deduplicated,
///     in order of first appearance.
///   - `extractValidAgents(text, state)` — like `parseReferences` but validates each
///     name against the agent registry and returns matching `AgentRecord` values.

import Text "mo:core/Text";
import Char "mo:core/Char";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import AgentModel "../models/agent-model";

module {

  // ============================================
  // Private character helpers
  // ============================================

  /// Returns true if `c` is a word character: `[a-zA-Z0-9_]`.
  private func isWordChar(c : Char) : Bool {
    (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
  };

  /// Returns true if `c` is a valid first character of an agent name: `[a-z]`.
  private func isAgentNameStart(c : Char) : Bool {
    c >= 'a' and c <= 'z';
  };

  /// Returns true if `c` is a valid subsequent character of an agent name: `[a-z0-9-]`.
  private func isAgentNameChar(c : Char) : Bool {
    (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
  };

  // ============================================
  // Private helpers
  // ============================================

  /// Build a Text from chars[start..end) by concatenating each character.
  /// Agent names are short (typically < 64 chars), so this is efficient enough.
  private func charsToText(chars : [Char], start : Nat, end_ : Nat) : Text {
    var t = "";
    var i = start;
    while (i < end_) {
      t #= Text.fromChar(chars[i]);
      i += 1;
    };
    t;
  };

  /// Returns true if `name` is already present in `seen` (linear scan).
  private func alreadySeen(seen : [Text], name : Text) : Bool {
    for (s in seen.vals()) {
      if (s == name) return true;
    };
    false;
  };

  // ============================================
  // Public API
  // ============================================

  /// Parse all `::name` references from `text`.
  ///
  /// The scan proceeds left-to-right:
  ///   1. A triple-backtick (` ``` `) starts a fenced code block.  The scanner looks
  ///      ahead for a matching closing ` ``` `.  If found, everything between the delimiters
  ///      is skipped.  If no closing ` ``` ` exists, the triple backtick is treated as
  ///      literal text (no code block is entered).
  ///   2. A single backtick (`` ` ``) outside a fenced block starts inline code.  The
  ///      scanner looks ahead for a matching closing backtick (that is not part of a
  ///      triple-backtick sequence).  If found, everything between is skipped.  If no
  ///      closing backtick exists, the backtick is treated as literal text.
  ///   3. Outside any code context, the two-character sequence `::` begins a potential
  ///      reference.  It is accepted only when:
  ///        a. NOT immediately preceded by a word character (`[a-zA-Z0-9_]`), and
  ///        b. NOT immediately preceded by a backslash (`\`), and
  ///        c. The very next character starts a valid agent name (`[a-z]`).
  ///   4. The name is collected greedily while characters satisfy `[a-z0-9-]`.
  ///
  /// Returns deduplicated lowercase names in order of first appearance.
  public func parseReferences(text : Text) : [Text] {
    let chars = Iter.toArray(Text.toIter(text));
    let n = chars.size();

    var results : [Text] = [];
    var seen : [Text] = [];

    var i = 0;

    while (i < n) {
      let c = chars[i];

      // ── Check for triple-backtick (fenced code block) ─────────────────────
      if (c == '`' and i + 2 < n and chars[i + 1] == '`' and chars[i + 2] == '`') {
        // Look ahead for closing ```
        let searchStart = i + 3;
        var found = false;
        var j = searchStart;
        label search while (j + 2 < n) {
          if (chars[j] == '`' and chars[j + 1] == '`' and chars[j + 2] == '`') {
            // Found closing ``` — skip everything up to and including it
            i := j + 3;
            found := true;
            break search;
          };
          j += 1;
        };
        if (not found) {
          // No closing ``` found — treat as literal, advance past the 3 backticks
          i += 3;
        };

        // ── Check for single backtick (inline code) ───────────────────────────
      } else if (c == '`') {
        // Look ahead for a matching closing backtick (not part of a triple)
        var j = i + 1;
        var found = false;
        label search while (j < n) {
          if (chars[j] == '`') {
            // Make sure this isn't the start of a triple-backtick
            if (j + 2 < n and chars[j + 1] == '`' and chars[j + 2] == '`') {
              // This is a triple-backtick — skip it entirely so it doesn't interfere
              j += 3;
            } else {
              // Found matching closing backtick — skip everything up to and including it
              i := j + 1;
              found := true;
              break search;
            };
          } else {
            j += 1;
          };
        };
        if (not found) {
          // No closing backtick found — treat as literal character
          i += 1;
        };

        // ── Check for `::` ────────────────────────────────────────────────────
      } else if (c == ':' and i + 1 < n and chars[i + 1] == ':') {
        let precededByWord = i > 0 and isWordChar(chars[i - 1]);
        let precededByBackslash = i > 0 and chars[i - 1] == '\\';

        if (not precededByWord and not precededByBackslash) {
          let nameStart = i + 2;
          if (nameStart < n and isAgentNameStart(chars[nameStart])) {
            // Collect name characters
            var j = nameStart;
            while (j < n and isAgentNameChar(chars[j])) {
              j += 1;
            };
            let name = charsToText(chars, nameStart, j);
            if (not alreadySeen(seen, name)) {
              results := Array.concat(results, [name]);
              seen := Array.concat(seen, [name]);
            };
            i := j; // resume after the consumed name
          } else {
            i += 2; // `::` not followed by a valid name start — skip
          };
        } else {
          i += 2; // escaped or word-prefixed `::` — skip
        };

      } else {
        i += 1;
      };
    };

    results;
  };

  /// Extract valid agent references from `text`, validated against the agent registry.
  ///
  /// Calls `parseReferences` to get the ordered, deduplicated name list, then looks
  /// up each name in `state` via `AgentModel.lookupByName` (case-insensitive, since
  /// names are stored lowercase in the registry).  Unknown names are silently dropped.
  ///
  /// Returns matching `AgentRecord` values in order of first appearance.
  public func extractValidAgents(
    text : Text,
    state : AgentModel.AgentRegistryState,
  ) : [AgentModel.AgentRecord] {
    let names = parseReferences(text);
    var matched : [AgentModel.AgentRecord] = [];
    for (name in names.vals()) {
      switch (AgentModel.lookupByName(name, state)) {
        case (?record) { matched := Array.concat(matched, [record]) };
        case (null) {};
      };
    };
    matched;
  };
};
