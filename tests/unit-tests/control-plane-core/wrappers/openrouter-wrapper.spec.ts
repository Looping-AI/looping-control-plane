import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
  TEST_API_KEY,
  TEST_MODEL,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

describe("OpenRouter Wrapper Unit Tests", () => {
  type TrackId = { workspace: bigint } | { workspaceAgent: [bigint, bigint] };

  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("Chat Method Tests", () => {
    it(
      "should fail with invalid model name",
      async () => {
        for (const model of ["", "   "]) {
          try {
            await testCanister.openRouterChat("test-key", "Hello", model);
            expect(false).toBe(true); // Should not reach here
          } catch (error) {
            expect(error).toBeDefined();
          }
        }
      },
      { timeout: 30000 },
    );

    it(
      "should handle basic chat with valid API key",
      async () => {
        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/basic-chat",
          () =>
            testCanister.openRouterChat(TEST_API_KEY, "Say hello", TEST_MODEL),
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
      },
      { timeout: 30000 },
    );

    it(
      "should handle unicode characters in message",
      async () => {
        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/unicode",
          () =>
            testCanister.openRouterChat(
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
      },
      { timeout: 30000 },
    );

    it(
      "should handle JSON-like content in message",
      async () => {
        const message =
          'What is the second child in this JSON: {"one": "two", "children": ["foo", "bar", "xyz"]}';

        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/json-content",
          () => testCanister.openRouterChat(TEST_API_KEY, message, TEST_MODEL),
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
      },
      { timeout: 30000 },
    );
  });

  describe("Reason Method Tests", () => {
    it(
      "should handle basic reasoning with string input",
      async () => {
        const trackId: TrackId = { workspaceAgent: [1n, 1n] };
        const input = "What are the key benefits of using renewable energy?";
        const instructions =
          "Provide a clear, structured response with main points.";

        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/reason-basic",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
            expect(response.ok.textResponse.toLowerCase()).toContain(
              "renewable",
            );
          } else {
            throw new Error("Unexpected tool calls response");
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 30000 },
    );

    it(
      "should handle reasoning without instructions or effort",
      async () => {
        const trackId: TrackId = { workspace: 4n };
        const input = "What is machine learning?";

        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/reason-no-instructions",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );

    it(
      "should fail with invalid API key",
      async () => {
        const trackId: TrackId = { workspaceAgent: [7n, 7n] };
        const input = "Test input";

        for (const apiKey of ["", "   "]) {
          try {
            await testCanister.openRouterReason(
              apiKey,
              [{ role: { user: null }, content: input }],
              TEST_MODEL,
              trackId,
              [],
              [],
              [],
            );
            expect(false).toBe(true); // Should not reach here
          } catch (error) {
            expect(error).toBeDefined();
          }
        }
      },
      { timeout: 30000 },
    );

    it(
      "should fail with empty input",
      async () => {
        const trackId: TrackId = { workspaceAgent: [9n, 9n] };

        try {
          await testCanister.openRouterReason(
            TEST_API_KEY,
            [],
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
      },
      { timeout: 30000 },
    );

    it(
      "should fail with empty model name",
      async () => {
        const trackId: TrackId = { workspaceAgent: [10n, 10n] };
        const input = "Test input";

        try {
          await testCanister.openRouterReason(
            TEST_API_KEY,
            [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );
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

    it(
      "should call a single tool when prompted",
      async () => {
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
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/tool-single-call",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );

    it(
      "should call appropriate tool from multiple available tools",
      async () => {
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
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/tool-select-from-multiple",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );

    it(
      "should parse tool call with complex nested parameters",
      async () => {
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
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/tool-complex-params",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );

    it(
      "should handle tool with no parameters",
      async () => {
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
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/tool-no-params",
          () =>
            testCanister.openRouterReason(
              TEST_API_KEY,
              [{ role: { user: null }, content: input }],
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
      },
      { timeout: 30000 },
    );
  });

  describe("Built-In Tools (useBuiltInTool) Tests", () => {
    it(
      "should handle web search without search settings",
      async () => {
        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/built-in-web-search-basic",
          () =>
            testCanister.openRouterUseBuiltInTool(
              TEST_API_KEY,
              "What happened in AI last week?",
              {
                web_search: { searchSettings: [] },
              },
            ),
          { ticks: 10 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.id).toBeDefined();
          expect(response.ok.model).toBe("openai/gpt-oss-120b");
          expect(response.ok.choices.length).toBeGreaterThan(0);

          const choice = response.ok.choices[0];
          expect(choice.message.content.length).toBeGreaterThan(0);

          // Should have executed tools
          const executedTools = choice.message.executed_tools[0];
          if (executedTools && executedTools.length > 0) {
            const tool = executedTools[0];
            if (tool && tool.tool_type === "search" && tool.search_results[0]) {
              const searchResults = tool.search_results[0];
              expect(searchResults.length).toBeGreaterThan(0);
              const firstResult = searchResults[0];
              if (firstResult) {
                expect(firstResult.title).toBeDefined();
                expect(firstResult.url).toBeDefined();
                expect(firstResult.content).toBeDefined();
                expect(firstResult.relevance_score).toBeGreaterThanOrEqual(0);
                expect(firstResult.relevance_score).toBeLessThanOrEqual(1);
              }
            }
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 30000 },
    );

    it(
      "should handle web search with max_results limit",
      async () => {
        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/built-in-web-search-exclude",
          () =>
            testCanister.openRouterUseBuiltInTool(
              TEST_API_KEY,
              "Tell me about the history of Bonsai trees in America",
              {
                web_search: {
                  searchSettings: [
                    {
                      max_results: [3n],
                    },
                  ],
                },
              },
            ),
          { ticks: 10 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.choices.length).toBeGreaterThan(0);
          const choice = response.ok.choices[0];
          expect(choice.message.content).toContain("Bonsai");

          // Verify results came back from the web search
          const executedTools = choice.message.executed_tools[0];
          if (executedTools && executedTools.length > 0) {
            const tool = executedTools[0];
            if (tool && tool.tool_type === "search" && tool.search_results[0]) {
              const searchResults = tool.search_results[0];
              expect(searchResults.length).toBeGreaterThan(0);
            }
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 60000 },
    );

    it(
      "should handle visit website with single URL",
      async () => {
        const { result } = await withCassette(
          pic,
          "unit-tests/control-plane-core/wrappers/openrouter-wrapper/built-in-visit-website",
          () =>
            testCanister.openRouterUseBuiltInTool(
              TEST_API_KEY,
              "Summarize the key points of this page: https://openrouter.ai/docs/overview/principles",
              { visit_website: null },
            ),
          { ticks: 10 },
        );

        const response = await result;

        if ("ok" in response) {
          expect(response.ok.choices.length).toBeGreaterThan(0);
          const choice = response.ok.choices[0];
          expect(choice.message.content.length).toBeGreaterThan(0);

          // Should contain summary of the page
          const lowerContent = choice.message.content.toLowerCase();
          expect(
            lowerContent.includes("openrouter") ||
              lowerContent.includes("model"),
          ).toBe(true);

          // Should have executed visit tool
          const executedTools = choice.message.executed_tools[0];
          if (executedTools && executedTools.length > 0) {
            const tool = executedTools[0];
            if (tool && tool.tool_type === "visit") {
              // The URL is in the arguments field, and content is in tool.content
              const content = tool.content[0];
              if (content) {
                expect(content.length).toBeGreaterThan(0);
                expect(content.toLowerCase()).toContain("lpu");
              }
            }
          }
        } else {
          throw new Error(
            "Expected successful response but got error: " + response.err,
          );
        }
      },
      { timeout: 30000 },
    );

    it(
      "should fail with invalid API key",
      async () => {
        for (const apiKey of ["", "   "]) {
          try {
            await testCanister.openRouterUseBuiltInTool(
              apiKey,
              "Test message",
              {
                web_search: { searchSettings: [] },
              },
            );
            expect(false).toBe(true); // Should not reach here
          } catch (error) {
            expect(error).toBeDefined();
          }
        }
      },
      { timeout: 30000 },
    );

    it(
      "should fail with empty message",
      async () => {
        try {
          await testCanister.openRouterUseBuiltInTool(TEST_API_KEY, "", {
            web_search: { searchSettings: [] },
          });
          expect(false).toBe(true); // Should not reach here
        } catch (error) {
          expect(error).toBeDefined();
        }
      },
      { timeout: 30000 },
    );
  });
});
