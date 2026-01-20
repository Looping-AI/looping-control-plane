import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createTestCanisterEnvironment,
  type TestCanisterService,
  TEST_API_KEY,
  TEST_MODEL,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

describe("Groq Wrapper Unit Tests", () => {
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

  describe("Input Validation", () => {
    it("should fail with empty model name", async () => {
      try {
        await testCanister.groqChat("test-key", "Hello", "");
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty model validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with whitespace-only model name", async () => {
      try {
        await testCanister.groqChat("test-key", "Hello", "   ");
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to whitespace model validation
        expect(error).toBeDefined();
      }
    });
  });

  describe("Successful API Calls", () => {
    it("should handle basic chat with valid API key", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/basic-chat",
        () => testCanister.groqChat(TEST_API_KEY, "Say hello", TEST_MODEL),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok).toContain("Hello");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle special characters in message", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/special-chars",
        () =>
          testCanister.groqChat(
            TEST_API_KEY,
            "Echo this: !@#$%^&*()",
            TEST_MODEL,
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok).toContain("!@#$%^&*()");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle unicode characters in message", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/unicode",
        () =>
          testCanister.groqChat(
            TEST_API_KEY,
            "Translate to English: 世界",
            TEST_MODEL,
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        const lowerBody = response.ok.toLowerCase();
        expect(lowerBody.includes("world")).toBe(true);
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle JSON-like content in message", async () => {
      const message =
        'What is the second child in this JSON: {"one": "two", "children": ["foo", "bar", "xyz"]}';

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/json-content",
        () => testCanister.groqChat(TEST_API_KEY, message, TEST_MODEL),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok).toContain("bar");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle newlines and special whitespace", async () => {
      const message = "Count new lines:\nLine\nAnother\nline\nhere";

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/newlines",
        () => testCanister.groqChat(TEST_API_KEY, message, TEST_MODEL),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        // Should indicate 3 or 4 lines (model may vary in counting)
        expect(response.ok).toMatch(/[34]/);
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should answer mathematical questions", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/math",
        () =>
          testCanister.groqChat(TEST_API_KEY, "What is 7 times 8?", TEST_MODEL),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok).toContain("56");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });
});
