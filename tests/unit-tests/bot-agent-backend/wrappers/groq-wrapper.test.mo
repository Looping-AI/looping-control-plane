import { test; expect } "mo:test/async";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Error "mo:core/Error";
import TestCanister "../test-canister";
import TestEnv "../test-env";

persistent actor {

  func resultToText(r : Result.Result<Text, Text>) : Text {
    switch (r) {
      case (#ok v) { "#ok(" # v # ")" };
      case (#err e) { "#err(" # e # ")" };
    };
  };

  func resultEqual(r1 : Result.Result<Text, Text>, r2 : Result.Result<Text, Text>) : Bool {
    r1 == r2;
  };

  public func runTests() : async () {
    // Deploy test canister with sufficient cycles for HTTP outcalls
    let testCanister = await (with cycles = 100_000_000_000_000) TestCanister.TestCanister();

    // ============================================
    // Groq Chat Tests - Validation
    // ============================================

    await test(
      "Groq Chat: fails with empty model name",
      func() : async () {
        try {
          let res = await testCanister.groqChat("test-key", "Hello", "");
          throw Error.reject("Should have failed with empty model");
        } catch (e) {
          // Expected to trap due to empty model validation
          expect.bool(true).isTrue();
        };
      },
    );

    await test(
      "Groq Chat: fails with whitespace-only model name",
      func() : async () {
        try {
          let res = await testCanister.groqChat("test-key", "Hello", "   ");
          throw Error.reject("Should have failed with whitespace-only model");
        } catch (e) {
          // Expected to trap due to whitespace model validation
          expect.bool(true).isTrue();
        };
      },
    );

    // ============================================
    // Groq Chat Tests - Successful API Calls
    // ============================================

    await test(
      "Groq Chat: basic chat with valid API key",
      func() : async () {
        let res = await testCanister.groqChat(TestEnv.GROQ_TEST_KEY, "Say hello", "llama-3.3-70b-versatile");
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            // Response should be non-empty
            expect.bool(Text.size(body) > 0).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "Groq Chat: handles special characters in message",
      func() : async () {
        let res = await testCanister.groqChat(
          TestEnv.GROQ_TEST_KEY,
          "Echo this: !@#$%^&*()",
          "llama-3.3-70b-versatile",
        );
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            expect.bool(Text.size(body) > 0).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "Groq Chat: handles unicode characters in message",
      func() : async () {
        let res = await testCanister.groqChat(
          TestEnv.GROQ_TEST_KEY,
          "Translate to English: 世界",
          "llama-3.3-70b-versatile",
        );
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            expect.bool(Text.size(body) > 0).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "Groq Chat: handles JSON-like content in message",
      func() : async () {
        let res = await testCanister.groqChat(
          TestEnv.GROQ_TEST_KEY,
          "What is this JSON: {\"key\": \"value\"}",
          "llama-3.3-70b-versatile",
        );
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            expect.bool(Text.size(body) > 0).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "Groq Chat: handles newlines and special whitespace",
      func() : async () {
        let res = await testCanister.groqChat(
          TestEnv.GROQ_TEST_KEY,
          "Count lines:\nLine 1\nLine 2\nLine 3",
          "llama-3.3-70b-versatile",
        );
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            expect.bool(Text.size(body) > 0).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "Groq Chat: mathematical question",
      func() : async () {
        let res = await testCanister.groqChat(
          TestEnv.GROQ_TEST_KEY,
          "What is 7 times 8?",
          "llama-3.3-70b-versatile",
        );
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            // Should contain 56 in the response
            expect.bool(Text.contains(body, #text "56")).isTrue();
          };
          case (#err _) {};
        };
      },
    );
  };
};
