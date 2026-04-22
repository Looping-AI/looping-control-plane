import { test; suite; expect } "mo:test";
import JsonSanitizer "../../../../src/control-plane-core/utilities/json-sanitizer";

suite(
  "JsonSanitizer",
  func() {

    suite(
      "sanitizeJsonSurrogates — surrogate pair resolution",
      func() {

        test(
          "valid high+low surrogate pair is combined into the real Unicode character",
          func() {
            // \uD83C\uDF88 → U+1F388 🎈
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\uD83C\\uDF88")).equal("🎈");
          },
        );

        test(
          "surrogate pair embedded in surrounding text is resolved in place",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("hello \\uD83C\\uDF88 world")).equal("hello 🎈 world");
          },
        );

        test(
          "multiple surrogate pairs in the same string are all resolved",
          func() {
            // 🎈 U+1F388 and 🔥 U+1F525
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\uD83C\\uDF88\\uD83D\\uDD25")).equal("🎈🔥");
          },
        );

      },
    );

    suite(
      "sanitizeJsonSurrogates — lone surrogate replacement",
      func() {

        test(
          "lone high surrogate is replaced with U+FFFD",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\uD800")).equal("\u{FFFD}");
          },
        );

        test(
          "lone low surrogate is replaced with U+FFFD",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\uDC00")).equal("\u{FFFD}");
          },
        );

        test(
          "high surrogate followed by non-surrogate \\uXXXX emits replacement for each",
          func() {
            // \uD800\u0041 — high surrogate then 'A'; high gets replacement, low \u is passed through
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\uD800\\u0041")).equal("\u{FFFD}\\u0041");
          },
        );

      },
    );

    suite(
      "sanitizeJsonSurrogates — non-surrogate \\uXXXX passes through",
      func() {

        test(
          "non-surrogate \\uXXXX escape is left unchanged",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\u0041")).equal("\\u0041");
          },
        );

        test(
          "empty string returns empty string",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("")).equal("");
          },
        );

        test(
          "string with no escape sequences is returned unchanged",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("hello world")).equal("hello world");
          },
        );

      },
    );

    suite(
      "sanitizeJsonSurrogates — escaped backslash before \\uXXXX is not treated as a surrogate escape",
      func() {

        test(
          "\\\\uD83C (escaped backslash + literal uD83C) is passed through unchanged",
          func() {
            // Raw JSON text \\uD83C means a literal backslash followed by the
            // characters uD83C — it is NOT a \\uXXXX escape sequence.
            // The sanitizer must not interpret it as a surrogate and must leave it intact.
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\\\uD83C")).equal("\\\\uD83C");
          },
        );

        test(
          "\\\\uD83C\\\\uDF88 (both escapes prefixed by escaped backslash) is passed through unchanged",
          func() {
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\\\uD83C\\\\uDF88")).equal("\\\\uD83C\\\\uDF88");
          },
        );

        test(
          "\\\\\\uD83C\\uDF88 (literal backslash then real surrogate pair) resolves only the surrogate pair",
          func() {
            // Raw: \\\uD83C\uDF88 = escaped backslash (\\) + real surrogate pair (\uD83C\uDF88)
            // Expected: two literal backslash chars followed by the emoji
            expect.text(JsonSanitizer.sanitizeJsonSurrogates("\\\\\\uD83C\\uDF88")).equal("\\\\🎈");
          },
        );

      },
    );

  },
);
