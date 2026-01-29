import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Map "mo:core/Map";
import ConversationModel "../models/conversation-model";
import GroqWrapper "../wrappers/groq-wrapper";
import Constants "../constants";
import InstructionComposer "../instructions/instruction-composer";
import FunctionToolRegistry "../tools/function-tool-registry";
import McpToolRegistry "../tools/mcp-tool-registry";
import ToolExecutor "../tools/tool-executor";

module {

  // Maximum iterations for multi-turn tool execution loop
  let MAX_ITERATIONS : Nat = 10;

  // Execute admin talk using Groq LLM with multi-turn tool support
  public func executeAdminTalk(
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceId : Nat,
    message : Text,
    apiKey : Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    // Compose instructions for workspace admin context
    let instructions = InstructionComposer.compose(
      #workspaceAdmin,
      [],
      [],
    );

    // Combine tool definitions from both registries
    let functionToolDefs = FunctionToolRegistry.getAllDefinitions();
    let mcpToolDefs = McpToolRegistry.getAllDefinitions(mcpToolRegistry);
    let allTools = Array.concat(functionToolDefs, mcpToolDefs);
    let toolsOpt : ?[GroqWrapper.Tool] = if (allTools.size() == 0) null else ?allTools;

    // Multi-turn loop for tool execution
    // Build conversation history as array of messages
    let inputMessages = List.empty<GroqWrapper.ResponseInputMessage>();
    List.add(inputMessages, { role = #user; content = message });
    var iteration = 0;

    loop {
      let groqResult = await GroqWrapper.reason(
        apiKey,
        List.toArray(inputMessages),
        Constants.ADMIN_TALK_MODEL,
        #workspace(workspaceId),
        ?instructions,
        null,
        toolsOpt,
      );

      switch (groqResult) {
        case (#ok(#textResponse(response))) {
          // Final response - store conversation and return
          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            {
              author = #user;
              content = message;
              timestamp = Time.now();
            },
          );

          ConversationModel.addMessageToAdminConversation(
            adminConversations,
            workspaceId,
            {
              author = #agent;
              content = response;
              timestamp = Time.now();
            },
          );

          return #ok(response);
        };

        case (#ok(#toolCalls(calls))) {
          // Execute tool calls
          let toolResults = await ToolExecutor.execute(mcpToolRegistry, calls);

          // Add assistant message indicating tool calls were made
          List.add(
            inputMessages,
            {
              role = #assistant;
              content = "Using tools: " # Array.foldLeft<GroqWrapper.ToolCall, Text>(
                calls,
                "",
                func(acc, call) {
                  if (acc == "") call.toolName else acc # ", " # call.toolName;
                },
              );
            },
          );

          // Add tool results as user message
          let formattedResults = ToolExecutor.formatResultsForLlm(toolResults);
          List.add(inputMessages, { role = #assistant; content = formattedResults });

          iteration += 1;
          if (iteration >= MAX_ITERATIONS) {
            return #err("Max tool iterations reached (" # Nat.toText(MAX_ITERATIONS) # ")");
          };
          // Continue loop
        };

        case (#err(error)) {
          return #err("Groq API Error: " # error);
        };
      };
    };
  };
};
