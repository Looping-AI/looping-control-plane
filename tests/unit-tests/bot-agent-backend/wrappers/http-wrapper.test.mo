import { suite; test; expect } "mo:test/async";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Debug "mo:core/Debug";
import TestCanister "../test-canister";
import HttpWrapper "../../../../src/bot-agent-backend/wrappers/http-wrapper";

persistent actor {
  type HttpResponse = (Nat, Text);

  func resultToText(r : Result.Result<HttpResponse, Text>) : Text {
    switch (r) {
      case (#ok(status, body)) {
        "#ok(" # Nat.toText(status) # ", " # body # ")";
      };
      case (#err e) { "#err(" # e # ")" };
    };
  };

  func resultEqual(r1 : Result.Result<HttpResponse, Text>, r2 : Result.Result<HttpResponse, Text>) : Bool {
    r1 == r2;
  };

  public func runTests() : async () {
    // Deploy test canister with sufficient cycles for HTTP outcalls
    let testCanister = await (with cycles = 10_000_000_000_000) TestCanister.TestCanister();

    await suite(
      "HTTP Wrapper",
      func() : async () {

        // ============================================
        // HTTP GET Tests
        // ============================================

        await test(
          "HTTP GET: successful request returns ok and contains expected content",
          func() : async () {
            let res = await testCanister.httpGet("https://example.com", []);
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok(status, body)) {
                expect.nat(status).equal(200);
                expect.text(body).contains("Example Domain");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
              };
            };
          },
        );

        await test(
          "HTTP GET: handles invalid URLs and non-existent domains",
          func() : async () {
            // Invalid URL format
            let res1 = await testCanister.httpGet("not-a-valid-url", []);
            expect.result<HttpResponse, Text>(res1, resultToText, resultEqual).isErr();

            // Non-existent domain
            let res2 = await testCanister.httpGet("https://this-domain-definitely-does-not-exist-12345.com", []);
            expect.result<HttpResponse, Text>(res2, resultToText, resultEqual).isErr();
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
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok(status, responseBody)) {
                expect.nat(status).equal(200);
                expect.text(responseBody).contains("hello from ICP");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
              };
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
            expect.result<HttpResponse, Text>(res1, resultToText, resultEqual).isOk();

            // Form-encoded
            let formHeaders : [HttpWrapper.HttpHeader] = [
              {
                name = "Content-Type";
                value = "application/x-www-form-urlencoded";
              },
            ];
            let res2 = await testCanister.httpPost("https://httpbin.org/post", formHeaders, "key1=value1&key2=value2");
            expect.result<HttpResponse, Text>(res2, resultToText, resultEqual).isOk();

            // Empty body
            let res3 = await testCanister.httpPost("https://httpbin.org/post", [], "");
            expect.result<HttpResponse, Text>(res3, resultToText, resultEqual).isOk();
          },
        );

        await test(
          "HTTP POST: handles invalid URLs and non-existent endpoints",
          func() : async () {
            // Invalid URL
            let res1 = await testCanister.httpPost("not-a-valid-url", [], "test data");
            expect.result<HttpResponse, Text>(res1, resultToText, resultEqual).isErr();

            // Non-existent endpoint
            let res2 = await testCanister.httpPost("https://this-domain-definitely-does-not-exist-12345.com/api", [], "test data");
            expect.result<HttpResponse, Text>(res2, resultToText, resultEqual).isErr();
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
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
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
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
          },
        );

        await test(
          "HTTP GET: handles query parameters correctly",
          func() : async () {
            let res = await testCanister.httpGet("https://httpbin.org/get?param1=value1&param2=value2", []);
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok(status, body)) {
                expect.nat(status).equal(200);
                expect.text(body).contains("param1");
                expect.text(body).contains("param2");
                expect.text(body).contains("value2");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
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
            expect.result<HttpResponse, Text>(res, resultToText, resultEqual).isOk();
            switch (res) {
              case (#ok(status, body)) {
                expect.nat(status).equal(200);
                // httpbin.org/headers echoes back the headers
                expect.text(body).contains("X-Custom-Header-1");
                expect.text(body).contains("X-Custom-Header-2");
                expect.text(body).contains("value2");
              };
              case (#err e) {
                Debug.print("Err Response: " # e);
              };
            };
          },
        );
      },
    );
  };
};
