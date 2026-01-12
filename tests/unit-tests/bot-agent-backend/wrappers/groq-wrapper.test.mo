import { suite; test; expect } "mo:test/async";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Debug "mo:core/Debug";
import TestCanister "../test-canister";
import TestEnv "../test-env";

persistent actor {
  let TEST_MODEL : Text = "llama-3.3-70b-versatile";

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
    let testCanister = await (with cycles = 10_000_000_000_000) TestCanister.TestCanister();

    // ============================================
    // Groq Chat Tests - Validation
    // ============================================

    await suite(
      "Groq Wrapper",
      func() : async () {
        await test(
          "Groq Chat: fails with empty model name",
          func() : async () {
            try {
              ignore await testCanister.groqChat("test-key", "Hello", "");
              assert false; // Should have failed with empty model
            } catch (_e) {
              // Expected to trap due to empty model validation
              return;
            };
          },
        );

        await test(
          "Groq Chat: fails with whitespace-only model name",
          func() : async () {
            try {
              ignore await testCanister.groqChat("test-key", "Hello", "   ");
              assert false; // Should have failed with whitespace-only model
            } catch (_e) {
              // Expected to trap due to whitespace model validation
              return;
            };
          },
        );

        // ============================================
        // Groq Chat Tests - Successful API Calls
        // ============================================

        await test(
          "Groq Chat: basic chat with valid API key",
          func() : async () {
            let res = await testCanister.groqChat(TestEnv.GROQ_TEST_KEY, "Say hello", TEST_MODEL);
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                // Response should be non-empty
                expect.text(body).contains("Hello");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );

        await test(
          "Groq Chat: handles special characters in message",
          func() : async () {
            let res = await testCanister.groqChat(
              TestEnv.GROQ_TEST_KEY,
              "Echo this: !@#$%^&*()",
              TEST_MODEL,
            );
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                expect.text(body).contains("!@#$%^&*()");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );

        await test(
          "Groq Chat: handles unicode characters in message",
          func() : async () {
            let res = await testCanister.groqChat(
              TestEnv.GROQ_TEST_KEY,
              "Translate to English: 世界",
              TEST_MODEL,
            );
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                expect.text(body).contains("world");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );

        await test(
          "Groq Chat: handles JSON-like content in message",
          func() : async () {
            let res = await testCanister.groqChat(
              TestEnv.GROQ_TEST_KEY,
              "What is the second child in this JSON: {\"one\": \"two\", \"children\": [\"foo\", \"bar\", \"xyz\"]}",
              TEST_MODEL,
            );
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                expect.text(body).contains("bar");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );

        await test(
          "Groq Chat: handles newlines and special whitespace",
          func() : async () {
            let res = await testCanister.groqChat(
              TestEnv.GROQ_TEST_KEY,
              "Count lines:\nLine\nAnother\nline\nhere",
              TEST_MODEL,
            );
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                expect.text(body).contains("4");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );

        await test(
          "Groq Chat: mathematical question",
          func() : async () {
            let res = await testCanister.groqChat(
              TestEnv.GROQ_TEST_KEY,
              "What is 7 times 8?",
              TEST_MODEL,
            );
            expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok body) {
                // Should contain 56 in the response
                expect.text(body).contains("56");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
                assert false; // Should have a successful response
              };
            };
          },
        );
      },
    );
  };
};
