import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import type { _SERVICE } from "../../setup.ts";
import { createTestEnvironment } from "../../setup.ts";

describe("HTTP Requests", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("http_request (query)", () => {
    it("should return 200 with server name for GET requests", async () => {
      const response = await actor.http_request({
        method: "GET",
        url: "/",
        headers: [],
        body: new Uint8Array([]),
        certificate_version: [],
      });

      expect(response.status_code).toBe(200);
      expect(response.upgrade).toEqual([]); // Candid optional: [] means None (null)

      // Check that content-type header is present (along with certification headers)
      const contentTypeHeader = response.headers.find(
        ([key]) => key === "content-type",
      );
      expect(contentTypeHeader).toEqual(["content-type", "text/plain"]);

      // Decode the body to verify message
      const decoder = new TextDecoder();
      const bodyText = decoder.decode(new Uint8Array(response.body));
      expect(bodyText).toBe("Looping AI API Server");
    });

    it("should return upgrade = true for POST requests", async () => {
      const response = await actor.http_request({
        method: "POST",
        url: "/webhook/slack",
        headers: [["content-type", "application/json"]],
        body: new Uint8Array([]),
        certificate_version: [],
      });

      expect(response.status_code).toBe(200);
      expect(response.upgrade).toEqual([true]);
      expect(response.headers).toEqual([]);
      expect(response.body).toEqual(new Uint8Array([]));
    });

    it("should return 400 for unsupported HTTP methods", async () => {
      const response = await actor.http_request({
        method: "PUT",
        url: "/",
        headers: [],
        body: new Uint8Array([]),
        certificate_version: [],
      });

      expect(response.status_code).toBe(400);
      expect(response.upgrade).toEqual([]); // Candid optional: [] means None (null)

      // Check that content-type header is present (along with certification headers)
      const contentTypeHeader = response.headers.find(
        ([key]) => key === "content-type",
      );
      expect(contentTypeHeader).toEqual(["content-type", "text/plain"]);

      const decoder = new TextDecoder();
      const bodyText = decoder.decode(new Uint8Array(response.body));
      expect(bodyText).toBe("Bad Request");
    });
  });

  describe("http_request_update (update)", () => {
    it("should accept POST webhook and return success", async () => {
      // Create a valid Slack url_verification payload (doesn't require signature)
      const encoder = new TextEncoder();
      const payload = encoder.encode(
        JSON.stringify({
          type: "url_verification",
          challenge: "test-challenge-12345",
        }),
      );

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack",
        headers: [["content-type", "application/json"]],
        body: payload,
      });

      expect(response.status_code).toBe(200);
      expect(response.upgrade).toEqual([]);
      expect(response.headers).toEqual([["content-type", "text/plain"]]);

      const decoder = new TextDecoder();
      const bodyText = decoder.decode(new Uint8Array(response.body));
      // url_verification responses return the challenge value
      expect(bodyText).toBe("test-challenge-12345");
    });

    it("should handle empty POST body", async () => {
      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack",
        headers: [],
        body: new Uint8Array([]),
      });

      // Empty body should fail JSON parsing (empty string is not valid JSON)
      expect(response.status_code).toBe(400);

      const decoder = new TextDecoder();
      const bodyText = decoder.decode(new Uint8Array(response.body));
      expect(bodyText).toBe("Invalid payload");
    });
  });
});
