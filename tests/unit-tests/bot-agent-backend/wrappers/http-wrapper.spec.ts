import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createTestCanisterEnvironment,
  type TestCanisterService,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";
import type { HttpHeader } from "../../../builds/test-canister.did.d.ts";

describe("HTTP Wrapper Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanisterEnvironment();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("HTTP GET", () => {
    it("should successfully request example.com and return expected content", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/example-com-get",
        () => testCanister.httpGet("https://example.com", []),
        { ticks: 5 },
      );

      const response = await result;
      if ("ok" in response) {
        const [status, body] = response.ok;
        expect(Number(status)).toBe(200);
        expect(body).toContain("Example Domain");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle invalid URLs and non-existent domains", async () => {
      // Invalid URL format - should add https:// and succeed
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/get-invalid-url-format",
        () => testCanister.httpGet("www.example.com", []),
        { ticks: 5 },
      );
      const invalidFormatResult = await result;
      expect("ok" in invalidFormatResult).toBe(true);

      // Non-existent domain - mock a trap response
      const executeGetRequest = await testCanister.httpGet(
        "https://this-domain-definitely-does-not-exist-12345.com",
        [],
      );
      await pic.tick(5);

      const pendingHttpsOutcalls = await pic.getPendingHttpsOutcalls();
      const pendingRequest = pendingHttpsOutcalls[0];

      await pic.mockPendingHttpsOutcall({
        requestId: pendingRequest.requestId,
        subnetId: pendingRequest.subnetId,
        response: {
          type: "reject",
          statusCode: 4,
          message: "Trap caused by DNS resolution failure",
        },
      });

      const response = await executeGetRequest();
      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("#canister_reject");
        expect(response.err).toContain("Trap caused by DNS resolution failure");
      }
    });

    it("should handle query parameters correctly", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/query-parameters",
        () =>
          testCanister.httpGet(
            "https://httpbin.org/get?param1=value1&param2=value2",
            [],
          ),
        { ticks: 5 },
      );

      const response = await result;
      if ("ok" in response) {
        const [status, body] = response.ok;
        expect(Number(status)).toBe(200);
        expect(body).toContain("param1");
        expect(body).toContain("param2");
        expect(body).toContain("value2");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should send multiple custom headers", async () => {
      const headers: HttpHeader[] = [
        { name: "X-Custom-Header-1", value: "value1" },
        { name: "X-Custom-Header-2", value: "value2" },
        { name: "Accept", value: "application/json" },
      ];

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/custom-headers",
        () => testCanister.httpGet("https://httpbin.org/headers", headers),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        const [status, body] = response.ok;
        expect(Number(status)).toBe(200);
        // httpbin.org/headers echoes back the headers
        expect(body).toContain("X-Custom-Header-1");
        expect(body).toContain("X-Custom-Header-2");
        expect(body).toContain("value2");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });

  describe("HTTP POST", () => {
    it("should successfully POST JSON data and echo response", async () => {
      const headers: HttpHeader[] = [
        { name: "Content-Type", value: "application/json" },
      ];
      const body = JSON.stringify({ message: "hello from ICP" });

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-json",
        () => testCanister.httpPost("https://httpbin.org/post", headers, body),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        const [status, responseBody] = response.ok;
        expect(Number(status)).toBe(200);
        expect(responseBody).toContain("hello from ICP");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should work with different content types", async () => {
      // Plain text
      const plainHeaders: HttpHeader[] = [
        { name: "Content-Type", value: "text/plain" },
      ];

      const { result: plainResult } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-plain-text",
        () =>
          testCanister.httpPost(
            "https://httpbin.org/post",
            plainHeaders,
            "Plain text message",
          ),
        { ticks: 5 },
      );
      const plainResponse = await plainResult;
      expect("ok" in plainResponse).toBe(true);

      // Form-encoded
      const formHeaders: HttpHeader[] = [
        { name: "Content-Type", value: "application/x-www-form-urlencoded" },
      ];

      const { result: formResult } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-form",
        () =>
          testCanister.httpPost(
            "https://httpbin.org/post",
            formHeaders,
            "key1=value1&key2=value2",
          ),
        { ticks: 5 },
      );
      const formResponse = await formResult;
      expect("ok" in formResponse).toBe(true);

      // Empty body
      const { result: emptyResult } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-empty",
        () => testCanister.httpPost("https://httpbin.org/post", [], ""),
        { ticks: 5 },
      );
      const emptyResponse = await emptyResult;
      expect("ok" in emptyResponse).toBe(true);
    });

    it("should handle invalid URLs and non-existent endpoints", async () => {
      // Invalid URL format
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-invalid-url-format",
        () => testCanister.httpPost("httpbin.org/post", [], "test data"),
        { ticks: 5 },
      );
      const invalidUrlFormatResult = await result;
      expect("ok" in invalidUrlFormatResult).toBe(true);

      // Non-existent endpoint - mock a trap response
      const executePostRequest = await testCanister.httpPost(
        "https://this-domain-definitely-does-not-exist-12345.com/api",
        [],
        "test data",
      );
      await pic.tick(2);

      const pendingHttpsOutcalls = await pic.getPendingHttpsOutcalls();
      const pendingRequest = pendingHttpsOutcalls[0];

      await pic.mockPendingHttpsOutcall({
        requestId: pendingRequest.requestId,
        subnetId: pendingRequest.subnetId,
        response: {
          type: "reject",
          statusCode: 4,
          message: "Trap caused by DNS resolution failure",
        },
      });

      const response = await executePostRequest();
      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("#canister_reject");
        expect(response.err).toContain("Trap caused by DNS resolution failure");
      }
    });

    it("should handle special characters in body", async () => {
      const headers: HttpHeader[] = [
        { name: "Content-Type", value: "application/json" },
      ];
      const body = JSON.stringify({
        message: "Testing: !@#$%^&*()_+-=[]{}|;':,.<>?",
      });

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-special-chars",
        () => testCanister.httpPost("https://httpbin.org/post", headers, body),
        { ticks: 5 },
      );
      const response = await result;
      expect("ok" in response).toBe(true);
    });

    it("should handle unicode characters in body", async () => {
      const headers: HttpHeader[] = [
        { name: "Content-Type", value: "application/json" },
      ];
      const body = JSON.stringify({ message: "Hello 世界 🌍" });

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/http-wrapper/post-unicode",
        () => testCanister.httpPost("https://httpbin.org/post", headers, body),
        { ticks: 5 },
      );
      const response = await result;
      expect("ok" in response).toBe(true);
    });
  });
});
