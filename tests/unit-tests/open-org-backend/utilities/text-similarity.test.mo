import { test; suite; expect } "mo:test";
import TextSimilarity "../../../../src/open-org-backend/utilities/text-similarity";

// ============================================
// Suite: isSimilar  (threshold = 0.15)
// ============================================
//
// Covers: degenerate empty inputs, ratio boundary conditions at threshold 0.15,
// normalization behaviour (via the public isSimilar surface), realistic
// agent-response pairs, and threshold edge values.
//
// A threshold of 0.15 means: ratio = dist/maxLen < 0.15 → similar.
// For a string of length 20, the max tolerated distance is 2 (2/20 = 0.10 < 0.15).
// Distance 3 on 20 chars → 0.15 → NOT similar (strict less-than).

suite(
  "TextSimilarity - isSimilar (threshold = 0.15)",
  func() {

    let t : Float = 0.15;

    test(
      "both empty → true (degenerate identical)",
      func() {
        expect.bool(TextSimilarity.isSimilar("", "", t)).isTrue();
      },
    );

    test(
      "identical strings → true (ratio = 0.0)",
      func() {
        expect.bool(TextSimilarity.isSimilar("hello world", "hello world", t)).isTrue();
      },
    );

    test(
      "completely different short strings → false",
      func() {
        expect.bool(TextSimilarity.isSimilar("abc", "xyz", t)).isFalse();
      },
    );

    test(
      "one empty one non-empty → false (ratio = 1.0)",
      func() {
        expect.bool(TextSimilarity.isSimilar("", "hello", t)).isFalse();
        expect.bool(TextSimilarity.isSimilar("hello", "", t)).isFalse();
      },
    );

    test(
      "1-char change on a 20-char string (ratio 0.05) → true",
      func() {
        // "abcdefghijklmnopqrst" (20) vs same with last char changed (dist=1, ratio=0.05)
        expect.bool(TextSimilarity.isSimilar("abcdefghijklmnopqrst", "abcdefghijklmnopqrsu", t)).isTrue();
      },
    );

    test(
      "2-char change on a 20-char string (ratio 0.10) → true",
      func() {
        expect.bool(TextSimilarity.isSimilar("abcdefghijklmnopqrst", "abcdefghijklmnopqXYt", t)).isTrue();
      },
    );

    test(
      "3-char change on a 20-char string (ratio 0.15) → false (strict <)",
      func() {
        expect.bool(TextSimilarity.isSimilar("abcdefghijklmnopqrst", "XbcXefghijklmnopXrst", t)).isFalse();
      },
    );

    test(
      "case and whitespace differences normalize before comparison",
      func() {
        // "Hello   World" normalizes to "hello world"
        // "hello world" is identical to "hello world" → dist = 0 → similar
        expect.bool(TextSimilarity.isSimilar("Hello   World", "hello world", t)).isTrue();
      },
    );

    test(
      "near-duplicate long agent response → true",
      func() {
        let base = "the quarterly revenue targets have been updated to reflect new market conditions";
        // One word changed near the end (ratio well below 0.15)
        let nearDup = "the quarterly revenue targets have been updated to reflect new market situations";
        expect.bool(TextSimilarity.isSimilar(base, nearDup, t)).isTrue();
      },
    );

    test(
      "substantially different agent responses → false",
      func() {
        let a = "please review the attached financial report and provide feedback by friday";
        let b = "the weather forecast indicates heavy rainfall across the northern regions this week";
        expect.bool(TextSimilarity.isSimilar(a, b, t)).isFalse();
      },
    );

    test(
      "threshold of 0.0 — ratio is never strictly less than 0 so nothing is similar",
      func() {
        // ratio = 0.0 for identical strings; 0.0 < 0.0 is false
        expect.bool(TextSimilarity.isSimilar("hello", "hello", 0.0)).isFalse();
        expect.bool(TextSimilarity.isSimilar("hello", "hellx", 0.0)).isFalse();
      },
    );

    test(
      "threshold of 1.0 makes any two non-empty strings similar",
      func() {
        // ratio is always < 1.0 for non-empty strings (max dist = maxLen → ratio = 1.0,
        // which is NOT < 1.0 for fully-different strings; partially different will be < 1.0)
        expect.bool(TextSimilarity.isSimilar("hello", "world", 1.0)).isTrue();
        // Both empty with threshold 1.0 → true (degenerate path)
        expect.bool(TextSimilarity.isSimilar("", "", 1.0)).isTrue();
      },
    );

  },
);
