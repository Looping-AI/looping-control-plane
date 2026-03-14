import { test; suite; expect } "mo:test";
import UrlEncoding "../../../../src/control-plane-core/utilities/url-encoding";

suite(
  "UrlEncoding",
  func() {

    suite(
      "encodeQueryValue — unreserved characters pass through unchanged",
      func() {

        test(
          "lowercase letters are not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("abcdefghijklmnopqrstuvwxyz")).equal("abcdefghijklmnopqrstuvwxyz");
          },
        );

        test(
          "uppercase letters are not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("ABCDEFGHIJKLMNOPQRSTUVWXYZ")).equal("ABCDEFGHIJKLMNOPQRSTUVWXYZ");
          },
        );

        test(
          "digits are not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("0123456789")).equal("0123456789");
          },
        );

        test(
          "hyphen is not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("-")).equal("-");
          },
        );

        test(
          "underscore is not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("_")).equal("_");
          },
        );

        test(
          "dot is not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue(".")).equal(".");
          },
        );

        test(
          "tilde is not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("~")).equal("~");
          },
        );

        test(
          "empty string returns empty string",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("")).equal("");
          },
        );

        test(
          "mixed unreserved characters are not encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("Hello-World_123.~")).equal("Hello-World_123.~");
          },
        );

      },
    );

    suite(
      "encodeQueryValue — base64 characters are percent-encoded",
      func() {

        test(
          "= (equals) is encoded as %3D",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("=")).equal("%3D");
          },
        );

        test(
          "+ (plus) is encoded as %2B",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("+")).equal("%2B");
          },
        );

        test(
          "/ (slash) is encoded as %2F",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("/")).equal("%2F");
          },
        );

        test(
          "real Slack cursor dXNlcjpVMEc5V0ZYTlo= encodes only the trailing =",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("dXNlcjpVMEc5V0ZYTlo=")).equal("dXNlcjpVMEc5V0ZYTlo%3D");
          },
        );

        test(
          "cursor with + and / and = (a+b/c=d) encodes all three special chars",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("a+b/c=d")).equal("a%2Bb%2Fc%3Dd");
          },
        );

        test(
          "multiple trailing = characters are each encoded",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("abc==")).equal("abc%3D%3D");
          },
        );

        test(
          "base64 cursor with all three special chars (a+b/c=)",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("abc+def/ghi=")).equal("abc%2Bdef%2Fghi%3D");
          },
        );

      },
    );

    suite(
      "encodeQueryValue — other reserved URL characters are encoded",
      func() {

        test(
          "space is encoded as %20",
          func() {
            expect.text(UrlEncoding.encodeQueryValue(" ")).equal("%20");
          },
        );

        test(
          "& (ampersand) is encoded as %26",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("&")).equal("%26");
          },
        );

        test(
          "? (question mark) is encoded as %3F",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("?")).equal("%3F");
          },
        );

        test(
          "# (hash) is encoded as %23",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("#")).equal("%23");
          },
        );

        test(
          "@ (at) is encoded as %40",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("@")).equal("%40");
          },
        );

      },
    );

    suite(
      "encodeQueryValue — UTF-8 multi-byte characters are percent-encoded",
      func() {

        test(
          "é (U+00E9) encodes as %C3%A9",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("é")).equal("%C3%A9");
          },
        );

        test(
          "café encodes only the é",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("café")).equal("caf%C3%A9");
          },
        );

        test(
          "emoji 🎈 (U+1F388) encodes as %F0%9F%8E%88",
          func() {
            expect.text(UrlEncoding.encodeQueryValue("🎈")).equal("%F0%9F%8E%88");
          },
        );

      },
    );

  },
);
