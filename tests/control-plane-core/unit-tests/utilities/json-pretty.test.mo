import { test; suite; expect } "mo:test";
import JsonPretty "../../../../src/control-plane-core/utilities/json-pretty";
import Json "mo:json";

suite(
  "JsonPretty",
  func() {

    suite(
      "prettyPrint — scalar values",
      func() {

        test(
          "null prints as \"null\"",
          func() {
            expect.text(JsonPretty.prettyPrint(#null_, 0)).equal("null");
          },
        );

        test(
          "bool true prints as \"true\"",
          func() {
            expect.text(JsonPretty.prettyPrint(#bool(true), 0)).equal("true");
          },
        );

        test(
          "bool false prints as \"false\"",
          func() {
            expect.text(JsonPretty.prettyPrint(#bool(false), 0)).equal("false");
          },
        );

        test(
          "integer number prints as decimal",
          func() {
            expect.text(JsonPretty.prettyPrint(#number(#int(42)), 0)).equal("42");
          },
        );

        test(
          "plain string is double-quoted",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("hello"), 0)).equal("\"hello\"");
          },
        );

      },
    );

    suite(
      "prettyPrint — string escaping",
      func() {

        test(
          "double-quote in string is escaped as \\\"",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("say \"hi\""), 0)).equal("\"say \\\"hi\\\"\"");
          },
        );

        test(
          "backslash in string is escaped as \\\\",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("a\\b"), 0)).equal("\"a\\\\b\"");
          },
        );

        test(
          "newline in string is escaped as \\n",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("a\nb"), 0)).equal("\"a\\nb\"");
          },
        );

        test(
          "carriage return in string is escaped as \\r",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("a\rb"), 0)).equal("\"a\\rb\"");
          },
        );

        test(
          "tab in string is escaped as \\t",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("a\tb"), 0)).equal("\"a\\tb\"");
          },
        );

        test(
          "NUL byte (U+0000) is escaped as \\u0000",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("\u{00}"), 0)).equal("\"\\u0000\"");
          },
        );

        test(
          "backspace (U+0008) is escaped as \\u0008",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("\u{08}"), 0)).equal("\"\\u0008\"");
          },
        );

        test(
          "form feed (U+000C) is escaped as \\u000c",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("\u{0C}"), 0)).equal("\"\\u000c\"");
          },
        );

        test(
          "unit separator (U+001F) is escaped as \\u001f",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("\u{1F}"), 0)).equal("\"\\u001f\"");
          },
        );

        test(
          "space (U+0020) is not escaped",
          func() {
            expect.text(JsonPretty.prettyPrint(#string("a b"), 0)).equal("\"a b\"");
          },
        );

        test(
          "mixed control characters in a single string are all escaped",
          func() {
            // NUL + tab + backspace in one value
            expect.text(JsonPretty.prettyPrint(#string("\u{00}\t\u{08}"), 0)).equal("\"\\u0000\\t\\u0008\"");
          },
        );

      },
    );

    suite(
      "prettyPrint — empty collections",
      func() {

        test(
          "empty array prints as []",
          func() {
            expect.text(JsonPretty.prettyPrint(#array([]), 0)).equal("[]");
          },
        );

        test(
          "empty object prints as {}",
          func() {
            expect.text(JsonPretty.prettyPrint(#object_([] : [(Text, Json.Json)]), 0)).equal("{}");
          },
        );

      },
    );

    suite(
      "prettyPrint — indentation",
      func() {

        test(
          "single-element array has inner item on indented line",
          func() {
            expect.text(JsonPretty.prettyPrint(#array([#number(#int(1))]), 0)).equal("[\n  1\n]");
          },
        );

        test(
          "nested array increases indentation by 2 spaces per level",
          func() {
            expect.text(JsonPretty.prettyPrint(#array([#array([#number(#int(1))])]), 0)).equal("[\n  [\n    1\n  ]\n]");
          },
        );

        test(
          "single-field object has key-value on indented line",
          func() {
            expect.text(JsonPretty.prettyPrint(#object_([("k", #string("v"))]), 0)).equal("{\n  \"k\": \"v\"\n}");
          },
        );

        test(
          "object key containing control character has key escaped",
          func() {
            expect.text(JsonPretty.prettyPrint(#object_([("a\u{00}b", #null_)]), 0)).equal("{\n  \"a\\u0000b\": null\n}");
          },
        );

      },
    );

  },
);
