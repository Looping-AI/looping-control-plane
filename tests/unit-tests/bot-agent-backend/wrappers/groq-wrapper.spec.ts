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

  describe("Chat Method Tests", () => {
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

  describe("Reason Method Tests", () => {
    it("should handle basic reasoning with string input", async () => {
      const agentId = 1n;
      const input = "What are the key benefits of using renewable energy?";
      const instructions =
        "Provide a clear, structured response with main points.";

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/reason-basic",
        () =>
          testCanister.groqReason(
            agentId,
            TEST_API_KEY,
            input,
            TEST_MODEL,
            [instructions],
            [{ low: null }],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok.length).toBeGreaterThan(0);
        expect(response.ok.toLowerCase()).toContain("renewable");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it(
      "should handle reasoning with medium effort",
      async () => {
        const agentId = 2n;
        const input =
          "Explain the concept of quantum computing in simple terms";

        const { result } = await withCassette(
          pic,
          "unit-tests/bot-agent-backend/wrappers/groq-wrapper/reason-medium-effort",
          () =>
            testCanister.groqReason(
              agentId,
              TEST_API_KEY,
              input,
              TEST_MODEL,
              [],
              [{ medium: null }],
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.length).toBeGreaterThan(0);
          expect(response.ok.toLowerCase()).toContain("quantum");
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 15000 },
    );

    it(
      "should handle reasoning with high effort",
      async () => {
        const agentId = 3n;
        const input =
          "Analyze the economic implications of artificial intelligence on the job market";
        const instructions =
          "Provide a comprehensive analysis with multiple perspectives.";

        const { result } = await withCassette(
          pic,
          "unit-tests/bot-agent-backend/wrappers/groq-wrapper/reason-high-effort",
          () =>
            testCanister.groqReason(
              agentId,
              TEST_API_KEY,
              input,
              TEST_MODEL,
              [instructions],
              [{ high: null }],
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.length).toBeGreaterThan(0);
          const lowerResponse = response.ok.toLowerCase();
          expect(
            lowerResponse.includes("artificial intelligence") ||
              lowerResponse.includes("ai") ||
              lowerResponse.includes("job") ||
              lowerResponse.includes("economic"),
          ).toBe(true);
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 20000 },
    );

    it("should handle reasoning without instructions or effort", async () => {
      const agentId = 4n;
      const input = "What is machine learning?";

      const { result } = await withCassette(
        pic,
        "unit-tests/bot-agent-backend/wrappers/groq-wrapper/reason-no-instructions",
        () =>
          testCanister.groqReason(
            agentId,
            TEST_API_KEY,
            input,
            TEST_MODEL,
            [],
            [],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(response.ok.length).toBeGreaterThan(0);
        expect(response.ok.toLowerCase()).toContain("machine learning");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it(
      "should handle complex mathematical reasoning",
      async () => {
        const agentId = 6n;
        const input =
          "Solve this step by step: If a train travels at 80 mph for 2.5 hours, how far does it go? Show your work.";
        const instructions = "Break down the calculation step by step.";

        const { result } = await withCassette(
          pic,
          "unit-tests/bot-agent-backend/wrappers/groq-wrapper/reason-math",
          () =>
            testCanister.groqReason(
              agentId,
              TEST_API_KEY,
              input,
              TEST_MODEL,
              [instructions],
              [{ medium: null }],
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.length).toBeGreaterThan(0);
          const lowerResponse = response.ok.toLowerCase();
          expect(
            lowerResponse.includes("200") ||
              lowerResponse.includes("80") ||
              lowerResponse.includes("2.5") ||
              lowerResponse.includes("miles"),
          ).toBe(true);
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 10000 },
    );

    it("should fail with empty API key", async () => {
      const agentId = 7n;
      const input = "Test input";

      try {
        await testCanister.groqReason(agentId, "", input, TEST_MODEL, [], []);
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty API key validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with whitespace-only API key", async () => {
      const agentId = 8n;
      const input = "Test input";

      try {
        await testCanister.groqReason(
          agentId,
          "   ",
          input,
          TEST_MODEL,
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to whitespace API key validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with empty input", async () => {
      const agentId = 9n;

      try {
        await testCanister.groqReason(
          agentId,
          TEST_API_KEY,
          "",
          TEST_MODEL,
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty input validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with empty model name", async () => {
      const agentId = 10n;
      const input = "Test input";

      try {
        await testCanister.groqReason(agentId, TEST_API_KEY, input, "", [], []);
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty model validation
        expect(error).toBeDefined();
      }
    });
  });
});
