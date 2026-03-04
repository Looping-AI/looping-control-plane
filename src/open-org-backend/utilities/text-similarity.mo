/// Text Similarity
///
/// Utilities for detecting near-duplicate text responses, used by the agent
/// router to identify stuck similarity loops.
///
/// Public surface:
///   - `isSimilar` — returns true when two strings are considered near-duplicates

import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Float "mo:core/Float";

module {

  // ─── Private helpers ─────────────────────────────────────────────────────────

  /// Normalize a string for similarity comparison:
  ///   - Lowercase
  ///   - Collapse runs of whitespace (space / tab / CR / LF) into a single space
  ///   - Strip leading and trailing whitespace (Text.tokens already does this)
  private func normalizeText(t : Text) : Text {
    let lowered = Text.toLower(t);
    // Text.tokens skips empty segments — no post-filter needed.
    let tokens = Text.tokens(
      lowered,
      #predicate(
        func(c : Char) : Bool {
          c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }
      ),
    );
    Text.join(tokens, " ");
  };

  /// Compute the Levenshtein edit distance between `a` and `b`.
  ///
  /// Inputs are capped at 1 000 characters so that the O(m·n) DP table stays
  /// within a reasonable instruction budget (≤ 1 000 × 1 000 = 1 M cells).
  ///
  /// The function operates on raw (un-normalized) strings so callers that need
  /// the raw distance can use it directly; callers wanting semantic comparison
  /// should normalize first via `normalizeText`.
  private func levenshtein(a : Text, b : Text) : Nat {
    let aArr = Array.fromIter(Iter.take(Text.toIter(a), 1_000));
    let bArr = Array.fromIter(Iter.take(Text.toIter(b), 1_000));
    let m = aArr.size();
    let n = bArr.size();
    if (m == 0) { return n };
    if (n == 0) { return m };

    // `prev[j]` = edit distance between a[0..i-1] and b[0..j-1] after row i-1.
    // Initialize with the trivial "delete all of b" baseline.
    var prev : [Nat] = Array.tabulate<Nat>(n + 1, func j { j });

    var i = 0;
    while (i < m) {
      let curr : [var Nat] = Array.toVarArray(Array.tabulate<Nat>(n + 1, func(_j) { 0 }));
      curr[0] := i + 1; // cost of deleting i+1 characters from a
      var j = 0;
      while (j < n) {
        let substCost = if (aArr[i] == bArr[j]) { 0 } else { 1 };
        let del = prev[j + 1] + 1; // delete aArr[i]
        let ins = curr[j] + 1; // insert bArr[j]
        let sub = prev[j] + substCost; // substitution
        curr[j + 1] := Nat.min(Nat.min(del, ins), sub);
        j += 1;
      };
      prev := Array.fromVarArray(curr);
      i += 1;
    };
    prev[n];
  };

  // ─── Public endpoint ──────────────────────────────────────────────────────────

  /// Return `true` when `a` and `b` are considered near-duplicates.
  ///
  /// Algorithm:
  ///   1. Normalize both strings (lowercase + collapsed whitespace).
  ///   2. Compute `d = levenshtein(normA, normB)`.
  ///   3. `ratio = d / max(len(normA), len(normB))`.
  ///   4. Return `ratio < threshold`.
  ///
  /// `threshold` is supplied by the caller so this function is purely testable
  /// without depending on any global constant.
  ///
  /// Edge cases:
  ///   - Both empty → ratio = 0.0 (< any positive threshold) → `true`.
  ///   - One empty, one non-empty → ratio = 1.0 (≥ threshold for any threshold ≤ 1) → `false`.
  public func isSimilar(a : Text, b : Text, threshold : Float) : Bool {
    let normA = normalizeText(a);
    let normB = normalizeText(b);
    let lenA = normA.size();
    let lenB = normB.size();
    let maxLen = Nat.max(lenA, lenB);
    if (maxLen == 0) { return true }; // both empty — degenerate case
    let dist = levenshtein(normA, normB);
    let ratio = Float.fromInt(dist) / Float.fromInt(maxLen);
    ratio < threshold;
  };
};
