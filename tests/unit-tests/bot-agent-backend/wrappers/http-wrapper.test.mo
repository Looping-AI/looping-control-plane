import { test; expect } "mo:test/async";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Error "mo:core/Error";
import TestCanister "../test-canister";
import HttpWrapper "../../../../src/bot-agent-backend/wrappers/http-wrapper";

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
    let testCanister = await (with cycles = 10_000_000_000_000) TestCanister.TestCanister();

    // ============================================
    // HTTP GET Tests
    // ============================================

    await test(
      "HTTP GET: successful request returns ok and contains expected content",
      func() : async () {
        let res = await testCanister.httpGet("https://example.com", []);
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok body) {
            expect.bool(Text.contains(body, #text "Example Domain")).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "HTTP GET: handles invalid URLs and non-existent domains",
      func() : async () {
        // Invalid URL format
        let res1 = await testCanister.httpGet("not-a-valid-url", []);
        expect.result<Text, Text>(res1, resultToText, resultEqual).isErr();

        // Non-existent domain
        let res2 = await testCanister.httpGet("https://this-domain-definitely-does-not-exist-12345.com", []);
        expect.result<Text, Text>(res2, resultToText, resultEqual).isErr();
      },
    );

    // ============================================
    // HTTP POST Tests
    // ============================================

    await test(
      "HTTP POST: successful JSON POST returns ok and echoes data",
      func() : async () {
        let headers : [HttpWrapper.HttpHeader] = [
          { name = "Content-Type"; value = "application/json" },
        ];
        let body = "{\"message\": \"hello from ICP\"}";
        let res = await testCanister.httpPost("https://httpbin.org/post", headers, body);
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
        switch (res) {
          case (#ok responseBody) {
            expect.bool(Text.contains(responseBody, #text "hello from ICP")).isTrue();
          };
          case (#err _) {};
        };
      },
    );

    await test(
      "HTTP POST: works with different content types",
      func() : async () {
        // Plain text
        let plainHeaders : [HttpWrapper.HttpHeader] = [
          { name = "Content-Type"; value = "text/plain" },
        ];
        let res1 = await testCanister.httpPost("https://httpbin.org/post", plainHeaders, "Plain text message");
        expect.result<Text, Text>(res1, resultToText, resultEqual).isOk();

        // Form-encoded
        let formHeaders : [HttpWrapper.HttpHeader] = [
          { name = "Content-Type"; value = "application/x-www-form-urlencoded" },
        ];
        let res2 = await testCanister.httpPost("https://httpbin.org/post", formHeaders, "key1=value1&key2=value2");
        expect.result<Text, Text>(res2, resultToText, resultEqual).isOk();

        // Empty body
        let res3 = await testCanister.httpPost("https://httpbin.org/post", [], "");
        expect.result<Text, Text>(res3, resultToText, resultEqual).isOk();
      },
    );

    await test(
      "HTTP POST: handles invalid URLs and non-existent endpoints",
      func() : async () {
        // Invalid URL
        let res1 = await testCanister.httpPost("not-a-valid-url", [], "test data");
        expect.result<Text, Text>(res1, resultToText, resultEqual).isErr();

        // Non-existent endpoint
        let res2 = await testCanister.httpPost("https://this-domain-definitely-does-not-exist-12345.com/api", [], "test data");
        expect.result<Text, Text>(res2, resultToText, resultEqual).isErr();
      },
    );

    // ============================================
    // Edge Cases and Special Characters
    // ============================================

    await test(
      "HTTP POST: handles special characters in body",
      func() : async () {
        let headers : [HttpWrapper.HttpHeader] = [
          { name = "Content-Type"; value = "application/json" },
        ];
        let body = "{\"message\": \"Testing: !@#$%^&*()_+-=[]{}|;':,.<>?\"}";
        let res = await testCanister.httpPost("https://httpbin.org/post", headers, body);
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
      },
    );

    await test(
      "HTTP POST: handles unicode characters in body",
      func() : async () {
        let headers : [HttpWrapper.HttpHeader] = [
          { name = "Content-Type"; value = "application/json" },
        ];
        let body = "{\"message\": \"Hello 世界 🌍\"}";
        let res = await testCanister.httpPost("https://httpbin.org/post", headers, body);
        expect.result<Text, Text>(res, resultToText, resultEqual).isOk();
      },
    );

    await test(
      "HTTP GET: handles query parameters correctly",
      func() : async () {
        let res = await testCanister.httpGet("https://httpbin.org/get?param1=value1&param2=value2", []);
        switch (res) {
          case (#ok body) {
            expect.bool(Text.contains(body, #text "param1")).isTrue();
            expect.bool(Text.contains(body, #text "param2")).isTrue();
            expect.bool(Text.contains(body, #text "value2")).isTrue();
          };
          case (#err msg) {
            throw Error.reject("Request should not have failed: " # msg);
          };
        };
      },
    );

    await test(
      "HTTP GET: multiple custom headers are sent",
      func() : async () {
        let headers : [HttpWrapper.HttpHeader] = [
          { name = "X-Custom-Header-1"; value = "value1" },
          { name = "X-Custom-Header-2"; value = "value2" },
          { name = "Accept"; value = "application/json" },
        ];
        let res = await testCanister.httpGet("https://httpbin.org/headers", headers);
        switch (res) {
          case (#ok body) {
            // httpbin.org/headers echoes back the headers
            expect.bool(
              Text.contains(body, #text "X-Custom-Header-1")
            ).isTrue();
            expect.bool(
              Text.contains(body, #text "X-Custom-Header-2")
            ).isTrue();
            expect.bool(
              Text.contains(body, #text "value2")
            ).isTrue();
          };
          case (#err msg) {
            throw Error.reject("Request should not have failed: " # msg);
          };
        };
      },
    );
  };
};
