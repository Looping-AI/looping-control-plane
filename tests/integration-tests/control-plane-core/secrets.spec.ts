import { afterEach, beforeEach, describe, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../setup.ts";
import { createBackendCanister } from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";

// ============================================
// storeOrgCriticalSecrets Integration Tests
//
// Exercises the canister's controller-gated secret storage method directly.
// The beforeEach in http-request-update.spec.ts uses this method as a setup
// guard — the explicit contract (authorization + all secret types) lives here.
// ============================================

describe("storeOrgCriticalSecrets", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
    actor = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ============================================
  // Authorization
  // ============================================

  describe("authorization", () => {
    it("should store slackSigningSecret successfully as controller", async () => {
      expectOk(
        await actor.storeOrgCriticalSecrets(
          { slackSigningSecret: null },
          "test-signing-secret-value",
        ),
      );
    });

    it("should reject non-controller caller", async () => {
      // Switch to a random identity that is not a canister controller
      const nonController = generateRandomIdentity();
      actor.setIdentity(nonController);

      expectErr(
        await actor.storeOrgCriticalSecrets(
          { slackSigningSecret: null },
          "some-value",
        ),
      );
    });

    it("should reject empty secret value", async () => {
      expectErr(
        await actor.storeOrgCriticalSecrets({ slackSigningSecret: null }, ""),
      );
    });
  });

  // ============================================
  // All supported secret types
  // ============================================

  describe("secret types", () => {
    it("should store openRouterApiKey without error", async () => {
      expectOk(
        await actor.storeOrgCriticalSecrets(
          { openRouterApiKey: null },
          "gsk_test_key",
        ),
      );
    });

    it("should store openaiApiKey without error", async () => {
      expectOk(
        await actor.storeOrgCriticalSecrets(
          { openaiApiKey: null },
          "sk-test-key",
        ),
      );
    });

    it("should store slackBotToken without error", async () => {
      expectOk(
        await actor.storeOrgCriticalSecrets(
          { slackBotToken: null },
          "xoxb-test-token",
        ),
      );
    });

    it("should store slackSigningSecret without error", async () => {
      expectOk(
        await actor.storeOrgCriticalSecrets(
          { slackSigningSecret: null },
          "test-signing-secret",
        ),
      );
    });
  });
});
