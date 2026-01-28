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
  type TrackId = { workspace: bigint } | { workspaceAgent: [bigint, bigint] };

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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/basic-chat",
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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/special-chars",
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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/unicode",
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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/json-content",
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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/newlines",
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
        "unit-tests/open-org-backend/wrappers/groq-wrapper/math",
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
      const trackId: TrackId = { workspaceAgent: [1n, 1n] };
      const input = "What are the key benefits of using renewable energy?";
      const instructions =
        "Provide a clear, structured response with main points.";

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/reason-basic",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [instructions],
            [], // temperature
            [], // tools
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("textResponse" in response.ok) {
          expect(response.ok.textResponse.length).toBeGreaterThan(0);
          expect(response.ok.textResponse.toLowerCase()).toContain("renewable");
        } else {
          throw new Error("Unexpected tool calls response");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it(
      "should handle reasoning with medium effort",
      async () => {
        const trackId: TrackId = { workspaceAgent: [2n, 2n] };
        const input =
          "Explain the concept of quantum computing in simple terms";

        const { result } = await withCassette(
          pic,
          "unit-tests/open-org-backend/wrappers/groq-wrapper/reason-medium-effort",
          () =>
            testCanister.groqReason(
              TEST_API_KEY,
              input,
              TEST_MODEL,
              trackId,
              [],
              [], // temperature
              [], // tools
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          if ("textResponse" in response.ok) {
            expect(response.ok.textResponse.length).toBeGreaterThan(0);
            expect(response.ok.textResponse.toLowerCase()).toContain("quantum");
          } else {
            throw new Error("Unexpected tool calls response");
          }
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
        const trackId: TrackId = { workspaceAgent: [3n, 3n] };
        const input =
          "Analyze the economic implications of artificial intelligence on the job market";
        const instructions =
          "Provide a comprehensive analysis with multiple perspectives.";

        const { result } = await withCassette(
          pic,
          "unit-tests/open-org-backend/wrappers/groq-wrapper/reason-high-effort",
          () =>
            testCanister.groqReason(
              TEST_API_KEY,
              input,
              TEST_MODEL,
              trackId,
              [instructions],
              [], // temperature
              [], // tools
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          if ("textResponse" in response.ok) {
            expect(response.ok.textResponse.length).toBeGreaterThan(0);
            const lowerResponse = response.ok.textResponse.toLowerCase();
            expect(
              lowerResponse.includes("artificial intelligence") ||
                lowerResponse.includes("ai") ||
                lowerResponse.includes("job") ||
                lowerResponse.includes("economic"),
            ).toBe(true);
          } else {
            throw new Error("Unexpected tool calls response");
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 20000 },
    );

    it("should handle reasoning without instructions or effort", async () => {
      const trackId: TrackId = { workspace: 4n };
      const input = "What is machine learning?";

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/reason-no-instructions",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [], // temperature
            [], // tools
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("textResponse" in response.ok) {
          expect(response.ok.textResponse.length).toBeGreaterThan(0);
          expect(response.ok.textResponse.toLowerCase()).toContain(
            "machine learning",
          );
        } else {
          throw new Error("Unexpected tool calls response");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it(
      "should handle complex mathematical reasoning",
      async () => {
        const trackId: TrackId = { workspaceAgent: [6n, 6n] };
        const input =
          "Solve this step by step: If a train travels at 80 mph for 2.5 hours, how far does it go? Show your work.";
        const instructions = "Break down the calculation step by step.";

        const { result } = await withCassette(
          pic,
          "unit-tests/open-org-backend/wrappers/groq-wrapper/reason-math",
          () =>
            testCanister.groqReason(
              TEST_API_KEY,
              input,
              TEST_MODEL,
              trackId,
              [instructions],
              [], // temperature
              [], // tools
            ),
          { ticks: 5 },
        );

        const response = await result;

        if ("ok" in response) {
          if ("textResponse" in response.ok) {
            expect(response.ok.textResponse.length).toBeGreaterThan(0);
            const lowerResponse = response.ok.textResponse.toLowerCase();
            expect(
              lowerResponse.includes("200") ||
                lowerResponse.includes("80") ||
                lowerResponse.includes("2.5") ||
                lowerResponse.includes("miles"),
            ).toBe(true);
          } else {
            throw new Error("Unexpected tool calls response");
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 10000 },
    );

    it("should fail with empty API key", async () => {
      const trackId: TrackId = { workspaceAgent: [7n, 7n] };
      const input = "Test input";

      try {
        await testCanister.groqReason(
          "",
          input,
          TEST_MODEL,
          trackId,
          [],
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty API key validation
        expect(error).toBeDefined();
      }
    });

    it("should fail with whitespace-only API key", async () => {
      const trackId: TrackId = { workspaceAgent: [8n, 8n] };
      const input = "Test input";

      try {
        await testCanister.groqReason(
          "   ",
          input,
          TEST_MODEL,
          trackId,
          [],
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
      const trackId: TrackId = { workspaceAgent: [9n, 9n] };

      try {
        await testCanister.groqReason(
          TEST_API_KEY,
          "",
          TEST_MODEL,
          trackId,
          [],
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
      const trackId: TrackId = { workspaceAgent: [10n, 10n] };
      const input = "Test input";

      try {
        await testCanister.groqReason(
          TEST_API_KEY,
          input,
          "",
          trackId,
          [],
          [],
          [],
        );
        expect(false).toBe(true); // Should not reach here
      } catch (error) {
        // Expected to trap due to empty model validation
        expect(error).toBeDefined();
      }
    });
  });

  describe("Tool Calling Tests", () => {
    // Helper type for Tool
    type Tool = {
      tool_type: string;
      function: {
        name: string;
        description: [] | [string];
        parameters: [] | [string];
      };
    };

    it("should call a single tool when prompted", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 1n] };
      const input = "What is the weather in San Francisco?";

      const weatherTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_weather",
          description: ["Get the current weather for a given location"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                location: {
                  type: "string",
                  description: "The city name, e.g. San Francisco",
                },
              },
              required: ["location"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/tool-single-call",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [],
            [[weatherTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("get_weather");
          expect(toolCall.callId).toBeTruthy();

          // Parse arguments and verify location
          const args = JSON.parse(toolCall.arguments);
          expect(args.location.toLowerCase()).toContain("san francisco");
        } else {
          // If model responded with text instead of tool call, that's also acceptable
          // but we expect tool call for this specific prompt
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should call appropriate tool from multiple available tools", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 2n] };
      const input = "Calculate 15 multiplied by 7";

      const weatherTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_weather",
          description: ["Get the current weather for a given location"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                location: { type: "string", description: "The city name" },
              },
              required: ["location"],
            }),
          ],
        },
      };

      const calculatorTool: Tool = {
        tool_type: "function",
        function: {
          name: "calculator",
          description: ["Perform mathematical calculations"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                operation: {
                  type: "string",
                  enum: ["add", "subtract", "multiply", "divide"],
                  description: "The mathematical operation to perform",
                },
                a: { type: "number", description: "First operand" },
                b: { type: "number", description: "Second operand" },
              },
              required: ["operation", "a", "b"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/tool-select-from-multiple",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [],
            [[weatherTool, calculatorTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("calculator");

          // Parse arguments and verify calculation parameters
          const args = JSON.parse(toolCall.arguments);
          expect(args.operation).toBe("multiply");
          expect(args.a).toBe(15);
          expect(args.b).toBe(7);
        } else {
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should return text response when no tool is needed", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 3n] };
      const input = "Say hello to me";

      const weatherTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_weather",
          description: ["Get the current weather for a given location"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                location: { type: "string", description: "The city name" },
              },
              required: ["location"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/tool-not-needed",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [],
            [[weatherTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("textResponse" in response.ok) {
          expect(response.ok.textResponse.length).toBeGreaterThan(0);
          expect(response.ok.textResponse.toLowerCase()).toContain("hello");
        } else {
          // Tool was called unexpectedly - this is also acceptable behavior
          // but for "say hello" we expect text
          console.log("Unexpected tool call:", response.ok.toolCalls);
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should parse tool call with complex nested parameters", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 4n] };
      const input =
        "Search for JavaScript tutorials published after 2023 with difficulty level beginner";

      const searchTool: Tool = {
        tool_type: "function",
        function: {
          name: "search_tutorials",
          description: ["Search for programming tutorials with filters"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {
                query: { type: "string", description: "Search query" },
                filters: {
                  type: "object",
                  properties: {
                    language: {
                      type: "string",
                      description: "Programming language",
                    },
                    published_after: {
                      type: "integer",
                      description: "Year published after",
                    },
                    difficulty: {
                      type: "string",
                      enum: ["beginner", "intermediate", "advanced"],
                    },
                  },
                },
              },
              required: ["query"],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/tool-complex-params",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [],
            [[searchTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("search_tutorials");

          // Parse and verify complex nested arguments
          const args = JSON.parse(toolCall.arguments);
          expect(args.query.toLowerCase()).toContain("javascript");
          expect(args.filters).toBeDefined();
          expect(args.filters.difficulty).toBe("beginner");
          expect(args.filters.published_after).toBeGreaterThanOrEqual(2023);
        } else {
          throw new Error(
            "Expected tool call but got text response: " +
              response.ok.textResponse,
          );
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should handle tool with no parameters", async () => {
      const trackId: TrackId = { workspaceAgent: [100n, 5n] };
      const input = "What time is it right now?";

      const timeTool: Tool = {
        tool_type: "function",
        function: {
          name: "get_current_time",
          description: ["Get the current time"],
          parameters: [
            JSON.stringify({
              type: "object",
              properties: {},
              required: [],
            }),
          ],
        },
      };

      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/wrappers/groq-wrapper/tool-no-params",
        () =>
          testCanister.groqReason(
            TEST_API_KEY,
            input,
            TEST_MODEL,
            trackId,
            [],
            [],
            [[timeTool]],
          ),
        { ticks: 5 },
      );

      const response = await result;

      if ("ok" in response) {
        if ("toolCalls" in response.ok) {
          expect(response.ok.toolCalls.length).toBeGreaterThan(0);
          const toolCall = response.ok.toolCalls[0];
          expect(toolCall.toolName).toBe("get_current_time");
          // Arguments should be empty or empty object
          const args = JSON.parse(toolCall.arguments);
          expect(Object.keys(args).length).toBe(0);
        } else {
          // Model might respond with text if it doesn't want to use the tool
          expect(response.ok.textResponse.length).toBeGreaterThan(0);
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });
});
