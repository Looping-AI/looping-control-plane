import { test; suite; expect } "mo:test";
import TextUtils "../../../../src/control-plane-core/utilities/text-utils";

suite(
  "TextUtils - truncateMiddle",
  func() {
    test(
      "returns text unchanged when at or below maxChars",
      func() {
        expect.text(TextUtils.truncateMiddle("hello", 10)).equal("hello");
        expect.text(TextUtils.truncateMiddle("hello", 5)).equal("hello");
      },
    );

    test(
      "inserts [TRUNCATED] marker in the middle when over limit",
      func() {
        // "abcdefghij" = 10 chars, limit = 6 → first 3 + [TRUNCATED] + last 3
        let result = TextUtils.truncateMiddle("abcdefghij", 6);
        expect.text(result).equal("abc[TRUNCATED]hij");
      },
    );

    test(
      "handles odd maxChars — first half rounds down",
      func() {
        // "abcdefghij" = 10 chars, limit = 5 → first 2 + [TRUNCATED] + last 3
        let result = TextUtils.truncateMiddle("abcdefghij", 5);
        expect.text(result).equal("ab[TRUNCATED]hij");
      },
    );

    test(
      "handles maxChars = 0 — returns only marker",
      func() {
        let result = TextUtils.truncateMiddle("hello world", 0);
        expect.text(result).equal("[TRUNCATED]");
      },
    );

    test(
      "handles maxChars = 1 — marker + last char (first half rounds to zero)",
      func() {
        let result = TextUtils.truncateMiddle("hello world", 1);
        expect.text(result).equal("[TRUNCATED]d");
      },
    );

    test(
      "handles maxChars = 2 — one char each side",
      func() {
        let result = TextUtils.truncateMiddle("hello world", 2);
        expect.text(result).equal("h[TRUNCATED]d");
      },
    );

    test(
      "returns text unchanged when exactly at limit",
      func() {
        let s = "exactly";
        expect.text(TextUtils.truncateMiddle(s, 7)).equal("exactly");
      },
    );
  },
);
