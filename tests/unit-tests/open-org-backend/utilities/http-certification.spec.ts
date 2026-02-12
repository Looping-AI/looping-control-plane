import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";

describe("HttpCertification Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("certifySkipFallbackPath", () => {
    it("should certify paths at various nesting levels", async () => {
      await testCanister.httpCertCertifyPath("/");
      const result1 = await testCanister.httpCertCheckPath("/");
      expect("ok" in result1).toBe(true);
      if ("ok" in result1) {
        expect(result1.ok.exists).toBe(true);
        expect(result1.ok.path).toEqual(["http_expr", "", "<*>"]);
      }

      await testCanister.httpCertCertifyPath("/health");
      const result2 = await testCanister.httpCertCheckPath("/health");
      expect("ok" in result2).toBe(true);
      if ("ok" in result2) {
        expect(result2.ok.exists).toBe(true);
        expect(result2.ok.path).toEqual(["http_expr", "health", "<*>"]);
      }

      await testCanister.httpCertCertifyPath("/api/v1/status");
      const result3 = await testCanister.httpCertCheckPath("/api/v1/status");
      expect("ok" in result3).toBe(true);
      if ("ok" in result3) {
        expect(result3.ok.exists).toBe(true);
        expect(result3.ok.path).toEqual([
          "http_expr",
          "api",
          "v1",
          "status",
          "<*>",
        ]);
      }
    });

    it("should handle path with query parameters", async () => {
      await testCanister.httpCertCertifyPath("/search?q=test&limit=10");
      const result = await testCanister.httpCertCheckPath(
        "/search?q=test&limit=10",
      );
      expect("ok" in result).toBe(true);
      if ("ok" in result) {
        expect(result.ok.exists).toBe(true);
        // Query parameters should be stripped, so path is just /search
        expect(result.ok.path).toEqual(["http_expr", "search", "<*>"]);
      }
    });

    it("should certify multiple paths in same store", async () => {
      await testCanister.httpCertCertifyPath("/");
      await testCanister.httpCertCertifyPath("/health");
      await testCanister.httpCertCertifyPath("/api/status");

      // Verify all paths exist in the same tree
      const result1 = await testCanister.httpCertCheckPath("/");
      const result2 = await testCanister.httpCertCheckPath("/health");
      const result3 = await testCanister.httpCertCheckPath("/api/status");

      expect("ok" in result1 && result1.ok.exists).toBe(true);
      expect("ok" in result2 && result2.ok.exists).toBe(true);
      expect("ok" in result3 && result3.ok.exists).toBe(true);

      // All should have the same tree hash since they're in the same store
      if ("ok" in result1 && "ok" in result2 && "ok" in result3) {
        expect(result1.ok.treeHash).toEqual(result2.ok.treeHash);
        expect(result2.ok.treeHash).toEqual(result3.ok.treeHash);
      }
    });

    it("should allow recertifying same path", async () => {
      await testCanister.httpCertCertifyPath("/health");
      const result1 = await testCanister.httpCertCheckPath("/health");

      await testCanister.httpCertCertifyPath("/health");
      const result2 = await testCanister.httpCertCheckPath("/health");

      // Both should exist
      expect("ok" in result1 && result1.ok.exists).toBe(true);
      expect("ok" in result2 && result2.ok.exists).toBe(true);

      // Tree hash should remain the same after recertifying same path
      if ("ok" in result1 && "ok" in result2) {
        expect(result1.ok.treeHash).toEqual(result2.ok.treeHash);
      }
    });
  });

  describe("getSkipCertificationHeaders", () => {
    it("should return headers after certifying path", async () => {
      await testCanister.httpCertCertifyPath("/");

      const response = await testCanister.httpCertGetHeaders("/");
      expect("ok" in response).toBe(true);

      if ("ok" in response) {
        const headers = response.ok;
        expect(Array.isArray(headers)).toBe(true);
        expect(headers.length).toBe(2);

        // Verify format of headers
        expect(headers[0][0]).toBe("ic-certificate");
        expect(headers[1][0]).toBe("ic-certificateexpression");
      }
    });

    it("should strip query parameters when retrieving headers", async () => {
      await testCanister.httpCertCertifyPath("/search");

      // Request with query parameters should still get headers
      const response = await testCanister.httpCertGetHeaders(
        "/search?q=test&limit=10",
      );

      expect("ok" in response).toBe(true);

      // Verify the path without query params exists in the tree
      const checkResult = await testCanister.httpCertCheckPath("/search");
      expect("ok" in checkResult && checkResult.ok.exists).toBe(true);
    });

    it("should handle headers for uncertified path", async () => {
      // Don't certify anything, just try to get headers
      const response = await testCanister.httpCertGetHeaders("/uncertified");

      // Should still return successfully (empty array)
      expect("ok" in response).toBe(true);

      // Verify the uncertified path does not exist in the tree
      const checkResult = await testCanister.httpCertCheckPath("/uncertified");
      expect("ok" in checkResult).toBe(true);
      if ("ok" in checkResult) {
        expect(checkResult.ok.exists).toBe(false);
      }
    });
  });

  describe("integration workflows", () => {
    it("should handle complete certification workflow", async () => {
      // Certify multiple paths
      await testCanister.httpCertCertifyPath("/");
      await testCanister.httpCertCertifyPath("/health");
      await testCanister.httpCertCertifyPath("/api/v1/status");

      // Retrieve headers for each path
      const response1 = await testCanister.httpCertGetHeaders("/");
      const response2 = await testCanister.httpCertGetHeaders("/health");
      const response3 = await testCanister.httpCertGetHeaders("/api/v1/status");

      // All should return successfully
      expect("ok" in response1).toBe(true);
      expect("ok" in response2).toBe(true);
      expect("ok" in response3).toBe(true);

      // Verify all paths exist in the tree
      const check1 = await testCanister.httpCertCheckPath("/");
      const check2 = await testCanister.httpCertCheckPath("/health");
      const check3 = await testCanister.httpCertCheckPath("/api/v1/status");

      expect("ok" in check1 && check1.ok.exists).toBe(true);
      expect("ok" in check2 && check2.ok.exists).toBe(true);
      expect("ok" in check3 && check3.ok.exists).toBe(true);
    });

    it("should support recertification workflow", async () => {
      // Certify a path
      await testCanister.httpCertCertifyPath("/health");

      // Get headers
      const response1 = await testCanister.httpCertGetHeaders("/health");
      expect("ok" in response1).toBe(true);

      // Check path exists
      const check1 = await testCanister.httpCertCheckPath("/health");
      expect("ok" in check1 && check1.ok.exists).toBe(true);

      // Recertify same path (simulating postupgrade)
      await testCanister.httpCertCertifyPath("/health");

      // Get headers again
      const response2 = await testCanister.httpCertGetHeaders("/health");
      expect("ok" in response2).toBe(true);

      // Verify path still exists
      const check2 = await testCanister.httpCertCheckPath("/health");
      expect("ok" in check2 && check2.ok.exists).toBe(true);
    });

    it("should maintain state across multiple header retrievals", async () => {
      await testCanister.httpCertCertifyPath("/");

      // Get headers multiple times
      const response1a = await testCanister.httpCertGetHeaders("/");
      const response1b = await testCanister.httpCertGetHeaders("/");

      // All should return consistently
      expect("ok" in response1a).toBe(true);
      expect("ok" in response1b).toBe(true);

      // Results should be identical
      if ("ok" in response1a && "ok" in response1b) {
        expect(JSON.stringify(response1a.ok)).toBe(
          JSON.stringify(response1b.ok),
        );
      }

      // Verify path exists in tree
      const check = await testCanister.httpCertCheckPath("/");
      expect("ok" in check && check.ok.exists).toBe(true);
    });

    it("should handle store reinitialization", async () => {
      // Certify some paths
      await testCanister.httpCertCertifyPath("/");
      await testCanister.httpCertCertifyPath("/health");

      // Get initial tree hash
      const check1 = await testCanister.httpCertCheckPath("/");
      const initialTreeHash =
        "ok" in check1 ? check1.ok.treeHash : new Uint8Array();

      // Reinitialize store
      await testCanister.httpCertInit();

      // After reinitialization, paths should not exist
      const checkAfterInit1 = await testCanister.httpCertCheckPath("/");
      const checkAfterInit2 = await testCanister.httpCertCheckPath("/health");
      expect("ok" in checkAfterInit1 && checkAfterInit1.ok.exists).toBe(false);
      expect("ok" in checkAfterInit2 && checkAfterInit2.ok.exists).toBe(false);

      // Recertify paths
      await testCanister.httpCertCertifyPath("/");
      await testCanister.httpCertCertifyPath("/health");

      // Should still work
      const response1 = await testCanister.httpCertGetHeaders("/");
      const response2 = await testCanister.httpCertGetHeaders("/health");

      expect("ok" in response1).toBe(true);
      expect("ok" in response2).toBe(true);

      // Verify paths exist again
      const check3 = await testCanister.httpCertCheckPath("/");
      const check4 = await testCanister.httpCertCheckPath("/health");
      expect("ok" in check3 && check3.ok.exists).toBe(true);
      expect("ok" in check4 && check4.ok.exists).toBe(true);

      // New tree hash should match (same paths certified)
      if ("ok" in check3) {
        expect(check3.ok.treeHash).toEqual(initialTreeHash);
      }
    });
  });

  describe("validation", () => {
    it("should not trap when getting headers for certified path", async () => {
      await testCanister.httpCertCertifyPath("/api");
      const response = await testCanister.httpCertGetHeaders("/api");

      // Should always return a result (ok or err), not trap
      expect("ok" in response || "err" in response).toBe(true);

      // Verify path exists in tree
      const check = await testCanister.httpCertCheckPath("/api");
      expect("ok" in check && check.ok.exists).toBe(true);
    });

    it("should verify path was certified using helper method", async () => {
      await testCanister.httpCertCertifyPath("/verified");
      const response = await testCanister.httpCertGetHeaders("/verified");

      // Should return headers without error
      expect("ok" in response).toBe(true);
      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
      }

      // Verify path exists in tree using the new helper
      const check = await testCanister.httpCertCheckPath("/verified");
      expect("ok" in check).toBe(true);
      if ("ok" in check) {
        expect(check.ok.exists).toBe(true);
        expect(check.ok.path).toEqual(["http_expr", "verified", "<*>"]);
        // Tree hash should be non-empty
        expect(check.ok.treeHash.length).toBeGreaterThan(0);
      }
    });
  });
});
