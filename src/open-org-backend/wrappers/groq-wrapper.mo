import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Bool "mo:core/Bool";
import List "mo:core/List";
import HttpWrapper "./http-wrapper";
import Json "mo:json";
import { str; int; float; bool; obj; arr } "mo:json";

module {
  // ============================================
  // Types for Groq API
  // ============================================

  /// Tracking identifier for attribution and usage monitoring
  /// Used to identify the workspace or workspace+agent context for LLM API calls
  public type TrackId = {
    #workspace : Nat;
    #workspaceAgent : (Nat, Nat);
  };

  /// Message role in a conversation
  public type MessageRole = {
    #developer;
    #user;
    #assistant;
  };

  /// A single message in the conversation
  public type ChatMessage = {
    role : MessageRole;
    content : Text;
  };

  /// Request payload for Groq chat completions
  public type ChatCompletionRequest = {
    model : Text;
    messages : [ChatMessage];
    temperature : ?Float;
    max_tokens : ?Nat;
    top_p : ?Float;
    stream : ?Bool;
  };

  /// Choice from Groq response
  public type ChatChoice = {
    index : Nat;
    message : ChatMessage;
    finish_reason : ?Text;
  };

  /// Usage statistics from Groq response
  public type Usage = {
    prompt_tokens : Nat;
    completion_tokens : Nat;
    total_tokens : Nat;
  };

  /// Response payload from Groq chat completions
  public type ChatCompletionResponse = {
    id : Text;
    created : Nat;
    model : Text;
    choices : [ChatChoice];
    usage : ?Usage;
  };

  /// Role for Responses API input messages
  public type ResponseInputRole = {
    #user;
    #assistant;
    #system_;
    #developer;
  };

  /// Input message for Groq Responses API
  public type ResponseInputMessage = {
    role : ResponseInputRole;
    content : Text;
  };

  /// Input for Groq Responses API (array of messages)
  public type ResponseInput = [ResponseInputMessage];

  /// Reasoning configuration for Responses API
  public type ReasoningConfig = {
    effort : ?Text;
    summary : ?Bool;
  };

  /// Text format configuration
  public type TextFormat = {
    format_type : Text; // "text" or "json_schema"
  };

  /// Tool choice for Responses API
  public type ToolChoice = {
    #string : Text; // "none", "auto", "required"
    #objectDef : { tool_type : Text; function_name : Text };
  };

  /// Function definition for tools
  public type FunctionDef = {
    name : Text;
    description : ?Text;
    parameters : ?Text; // JSON schema as string
  };

  /// Tool definition
  public type Tool = {
    tool_type : Text; // "function"
    function : FunctionDef;
  };

  /// A tool call request from the LLM
  public type ToolCall = {
    callId : Text;
    toolName : Text;
    arguments : Text; // JSON string of arguments
  };

  /// Result from reason - follows #ok/#err pattern
  /// On success (#ok): contains either #textResponse or #toolCalls
  /// On failure (#err): contains error message
  public type ReasonWithToolsResult = {
    #ok : {
      #textResponse : Text;
      #toolCalls : [ToolCall];
    };
    #err : Text;
  };

  /// Request payload for Groq Responses API
  public type ResponseRequest = {
    input : ResponseInput;
    model : Text;
    instructions : ?Text;
    max_output_tokens : ?Nat;
    metadata : ?Text; // JSON string for custom key-value pairs
    parallel_tool_calls : ?Bool;
    reasoning : ?ReasoningConfig;
    service_tier : ?Text; // "auto", "default", "flex"
    store : ?Bool;
    stream : ?Bool;
    temperature : ?Float;
    text : ?TextFormat;
    tool_choice : ?ToolChoice;
    tools : ?[Tool];
    top_p : ?Float;
    truncation : ?Text; // "auto", "disabled"
    user : ?Text;
  };

  /// Output content from Responses API
  public type ResponseOutputContent = {
    content_type : Text; // "output_text"
    text : Text;
    annotations : [Text]; // Array of annotation strings
  };

  /// Message output from Responses API
  public type ResponseMessage = {
    output_type : Text; // "message"
    id : Text;
    status : Text; // "completed", "failed", "in_progress", "incomplete"
    role : Text; // "assistant"
    content : [ResponseOutputContent];
  };

  /// Response output array item
  public type ResponseOutput = {
    #message : ResponseMessage;
  };

  /// Usage details for Responses API
  public type ResponseUsage = {
    input_tokens : Nat;
    input_tokens_details : ?{ cached_tokens : Nat };
    output_tokens : Nat;
    output_tokens_details : ?{ reasoning_tokens : Nat };
    total_tokens : Nat;
  };

  /// Response payload from Groq Responses API
  public type ResponseData = {
    id : Text;
    objectType : Text; // "response"
    status : Text; // "completed", "failed", "in_progress", "incomplete"
    created_at : Nat;
    output : [ResponseOutput];
    previous_response_id : ?Text;
    model : Text;
    reasoning : ?ReasoningConfig;
    max_output_tokens : ?Nat;
    instructions : ?Text;
    text : ?TextFormat;
    tools : [Tool];
    tool_choice : ?ToolChoice;
    truncation : Text;
    metadata : ?Text;
    temperature : Float;
    top_p : Float;
    user : ?Text;
    service_tier : Text;
    error : ?Text;
    incomplete_details : ?Text;
    usage : ResponseUsage;
    parallel_tool_calls : Bool;
    store : Bool;
  };

  // ============================================
  // Constants
  // ============================================

  /// Groq API base URL
  private let GROQ_API_BASE_URL : Text = "https://api.groq.com/openai/v1";

  // ============================================
  // Helper Functions
  // ============================================

  /// Convert MessageRole to string for JSON serialization
  private func roleToString(role : MessageRole) : Text {
    switch (role) {
      case (#developer) { "developer" };
      case (#user) { "user" };
      case (#assistant) { "assistant" };
    };
  };

  /// Convert ResponseInputRole to string for JSON serialization
  private func responseInputRoleToString(role : ResponseInputRole) : Text {
    switch (role) {
      case (#user) { "user" };
      case (#assistant) { "assistant" };
      case (#system_) { "system" };
      case (#developer) { "developer" };
    };
  };

  /// Convert a ChatMessage to JSON
  private func messageToJson(message : ChatMessage) : Json.Json {
    obj([
      ("role", str(roleToString(message.role))),
      ("content", str(message.content)),
    ]);
  };

  /// Convert ResponseInputMessage to JSON
  private func responseInputMessageToJson(msg : ResponseInputMessage) : Json.Json {
    obj([
      ("role", str(responseInputRoleToString(msg.role))),
      ("content", str(msg.content)),
    ]);
  };

  /// Convert ResponseInput to JSON
  private func inputToJson(input : ResponseInput) : Json.Json {
    arr(Array.map<ResponseInputMessage, Json.Json>(input, responseInputMessageToJson));
  };

  /// Convert ToolChoice to JSON
  private func toolChoiceToJson(toolChoice : ToolChoice) : Json.Json {
    switch (toolChoice) {
      case (#string(choice)) { str(choice) };
      case (#objectDef(toolObj)) {
        obj([
          ("type", str(toolObj.tool_type)),
          ("function", obj([("name", str(toolObj.function_name))])),
        ]);
      };
    };
  };

  /// Convert Tool to JSON for Responses API
  /// Note: Responses API uses flat structure with name/description/parameters at top level
  private func toolToJson(tool : Tool) : Json.Json {
    let toolFields = List.empty<(Text, Json.Json)>();
    List.add(toolFields, ("type", str(tool.tool_type)));
    List.add(toolFields, ("name", str(tool.function.name)));

    switch (tool.function.description) {
      case (?desc) { List.add(toolFields, ("description", str(desc))) };
      case (null) {};
    };

    switch (tool.function.parameters) {
      case (?params) {
        // Parse the JSON schema string and add it
        switch (Json.parse(params)) {
          case (#ok(paramJson)) {
            List.add(toolFields, ("parameters", paramJson));
          };
          case (#err(_)) {}; // Skip if invalid JSON
        };
      };
      case (null) {};
    };

    obj(List.toArray(toolFields));
  };

  /// Serialize ResponseRequest to JSON string
  private func serializeResponseRequest(request : ResponseRequest) : Text {
    // Start with required fields
    let requestFields = List.empty<(Text, Json.Json)>();
    List.add(requestFields, ("input", inputToJson(request.input)));
    List.add(requestFields, ("model", str(request.model)));

    // Add optional parameters
    switch (request.instructions) {
      case (?inst) { List.add(requestFields, ("instructions", str(inst))) };
      case (null) {};
    };

    switch (request.max_output_tokens) {
      case (?tokens) {
        List.add(requestFields, ("max_output_tokens", int(tokens)));
      };
      case (null) {};
    };

    switch (request.metadata) {
      case (?meta) {
        // Parse the JSON metadata string
        switch (Json.parse(meta)) {
          case (#ok(metaJson)) {
            List.add(requestFields, ("metadata", metaJson));
          };
          case (#err(_)) {}; // Skip if invalid JSON
        };
      };
      case (null) {};
    };

    switch (request.parallel_tool_calls) {
      case (?parallel) {
        List.add(requestFields, ("parallel_tool_calls", bool(parallel)));
      };
      case (null) {};
    };

    switch (request.reasoning) {
      case (?reasoning) {
        let reasoningFields = List.empty<(Text, Json.Json)>();
        switch (reasoning.effort) {
          case (?effort) {
            List.add(reasoningFields, ("effort", str(effort)));
          };
          case (null) {};
        };
        switch (reasoning.summary) {
          case (?summary) {
            List.add(reasoningFields, ("summary", bool(summary)));
          };
          case (null) {};
        };
        List.add(requestFields, ("reasoning", obj(List.toArray(reasoningFields))));
      };
      case (null) {};
    };

    switch (request.service_tier) {
      case (?tier) { List.add(requestFields, ("service_tier", str(tier))) };
      case (null) {};
    };

    switch (request.store) {
      case (?store) { List.add(requestFields, ("store", bool(store))) };
      case (null) {};
    };

    switch (request.stream) {
      case (?stream) { List.add(requestFields, ("stream", bool(stream))) };
      case (null) {};
    };

    switch (request.temperature) {
      case (?temp) { List.add(requestFields, ("temperature", float(temp))) };
      case (null) {};
    };

    switch (request.text) {
      case (?textFormat) {
        List.add(requestFields, ("text", obj([("format", obj([("type", str(textFormat.format_type))]))])));
      };
      case (null) {};
    };

    switch (request.tool_choice) {
      case (?choice) {
        List.add(requestFields, ("tool_choice", toolChoiceToJson(choice)));
      };
      case (null) {};
    };

    switch (request.tools) {
      case (?tools) {
        List.add(requestFields, ("tools", arr(Array.map<Tool, Json.Json>(tools, toolToJson))));
      };
      case (null) {};
    };

    switch (request.top_p) {
      case (?p) { List.add(requestFields, ("top_p", float(p))) };
      case (null) {};
    };

    switch (request.truncation) {
      case (?trunc) { List.add(requestFields, ("truncation", str(trunc))) };
      case (null) {};
    };

    switch (request.user) {
      case (?user) { List.add(requestFields, ("user", str(user))) };
      case (null) {};
    };

    Json.stringify(obj(List.toArray(requestFields)), null);
  };

  /// Serialize ChatCompletionRequest to JSON string
  private func serializeChatCompletionRequest(request : ChatCompletionRequest) : Text {
    let messagesJson = arr(Array.map<ChatMessage, Json.Json>(request.messages, messageToJson));

    // Start with required fields in a list
    let requestFields = List.empty<(Text, Json.Json)>();
    List.add(requestFields, ("model", str(request.model)));
    List.add(requestFields, ("messages", messagesJson));

    // Add optional parameters individually
    switch (request.temperature) {
      case (?temp) {
        List.add(requestFields, ("temperature", float(temp)));
      };
      case (null) {};
    };

    switch (request.max_tokens) {
      case (?tokens) {
        List.add(requestFields, ("max_tokens", int(tokens)));
      };
      case (null) {};
    };

    switch (request.top_p) {
      case (?p) {
        List.add(requestFields, ("top_p", float(p)));
      };
      case (null) {};
    };

    switch (request.stream) {
      case (?s) {
        List.add(requestFields, ("stream", bool(s)));
      };
      case (null) {};
    };

    Json.stringify(obj(List.toArray(requestFields)), null);
  };

  /// Parse Groq Responses API response for tool calls or text content
  ///
  /// @param responseBody - Raw JSON response from Groq Responses API
  /// @returns ReasonWithToolsResult indicating text response, tool calls, or error
  private func parseResponsesApiWithToolCalls(responseBody : Text) : ReasonWithToolsResult {
    switch (Json.parse(responseBody)) {
      case (#err(error)) {
        #err("Failed to parse JSON response: " # debug_show error # ".");
      };
      case (#ok(json)) {
        // Look for the output array
        switch (Json.get(json, "output")) {
          case (null) {
            #err("Could not find output array in response.");
          };
          case (?outputArrayJson) {
            switch (outputArrayJson) {
              case (#array(outputs)) {
                // First, check for function_call outputs (tool calls)
                let toolCallsList = List.empty<ToolCall>();

                for (outputJson in outputs.vals()) {
                  switch (Json.get(outputJson, "type")) {
                    case (?typeJson) {
                      switch (typeJson) {
                        case (#string("function_call")) {
                          // Found a function call, extract details
                          let callIdOpt = switch (Json.get(outputJson, "call_id")) {
                            case (?#string(id)) { ?id };
                            case (_) { null };
                          };
                          let nameOpt = switch (Json.get(outputJson, "name")) {
                            case (?#string(n)) { ?n };
                            case (_) { null };
                          };
                          let argsOpt = switch (Json.get(outputJson, "arguments")) {
                            case (?#string(a)) { ?a };
                            case (_) { null };
                          };

                          switch (callIdOpt, nameOpt, argsOpt) {
                            case (?callId, ?name, ?args) {
                              List.add(
                                toolCallsList,
                                {
                                  callId;
                                  toolName = name;
                                  arguments = args;
                                },
                              );
                            };
                            case (_) {
                              // Skip malformed function call
                            };
                          };
                        };
                        case (_) {
                          // Not a function call, continue
                        };
                      };
                    };
                    case (null) {};
                  };
                };

                // If we found tool calls, return them
                let toolCallsArray = List.toArray(toolCallsList);
                if (toolCallsArray.size() > 0) {
                  return #ok(#toolCalls(toolCallsArray));
                };

                // Otherwise, look for text message output
                for (outputJson in outputs.vals()) {
                  switch (Json.get(outputJson, "type")) {
                    case (?typeJson) {
                      switch (typeJson) {
                        case (#string("message")) {
                          // Found the message output, get the content
                          switch (Json.get(outputJson, "content[0].text")) {
                            case (?textJson) {
                              switch (textJson) {
                                case (#string(content)) {
                                  return #ok(#textResponse(content));
                                };
                                case (_) {};
                              };
                            };
                            case (null) {};
                          };
                        };
                        case (_) {};
                      };
                    };
                    case (null) {};
                  };
                };

                #err("Could not find message output or tool calls in response.");
              };
              case (_) {
                #err("Output field is not an array.");
              };
            };
          };
        };
      };
    };
  };

  /// Parse Groq API response and extract the assistant's message content
  ///
  /// Uses the JSON library for robust parsing
  ///
  /// @param responseBody - Raw JSON response from Groq API
  /// @returns Result with extracted content or error message
  private func parseGroqResponse(responseBody : Text) : {
    #ok : Text;
    #err : Text;
  } {
    switch (Json.parse(responseBody)) {
      case (#err(error)) {
        #err("Failed to parse JSON response: " # debug_show error # ".");
      };
      case (#ok(json)) {
        // Try to get the content from choices[0].message.content
        switch (Json.get(json, "choices[0].message.content")) {
          case (null) {
            #err("Could not find choices[0].message.content in response.");
          };
          case (?contentJson) {
            switch (contentJson) {
              case (#string(content)) {
                #ok(content);
              };
              case (_) {
                #err("Content field is not a string.");
              };
            };
          };
        };
      };
    };
  };

  // ============================================
  // Private Functions
  // ============================================

  /// Create response using Groq Responses API
  ///
  /// @param apiKey - The Groq API key
  /// @param input - Input text or array of texts
  /// @param model - Model name
  /// @param instructions - Optional system instructions
  /// @param temperature - Optional temperature setting (0.0-2.0)
  /// @param maxOutputTokens - Optional maximum output tokens
  /// @param reasoning - Optional reasoning configuration
  /// @param tools - Optional tools for function calling
  /// @param toolChoice - Optional tool choice configuration
  /// @param user - Optional user identifier
  /// @returns ReasonWithToolsResult indicating text response, tool calls, or error
  private func createResponse(
    apiKey : Text,
    input : ResponseInput,
    model : Text,
    instructions : ?Text,
    temperature : ?Float,
    maxOutputTokens : ?Nat,
    reasoning : ?ReasoningConfig,
    tools : ?[Tool],
    toolChoice : ?ToolChoice,
    user : ?Text,
  ) : async ReasonWithToolsResult {
    let request : ResponseRequest = {
      input;
      model;
      instructions;
      max_output_tokens = maxOutputTokens;
      metadata = null;
      parallel_tool_calls = null;
      reasoning;
      service_tier = null;
      store = ?false;
      stream = ?false; // Always false for simplicity
      temperature;
      text = null;
      tool_choice = toolChoice;
      tools;
      top_p = null;
      truncation = null;
      user;
    };

    let requestBody = serializeResponseRequest(request);
    let url = GROQ_API_BASE_URL # "/responses";

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # apiKey },
      { name = "Content-Type"; value = "application/json" },
    ];

    // Make the HTTP POST request
    let httpResult = await HttpWrapper.post(url, headers, requestBody);

    switch (httpResult) {
      case (#err(error)) {
        #err("HTTP request failed: " # error # ".");
      };
      case (#ok((status, responseBody))) {
        if (status == 200) {
          // Parse successful response with tool call support
          parseResponsesApiWithToolCalls(responseBody);
        } else {
          // Return error with status and response details
          #err("Groq Responses API returned status " # Nat.toText(status) # ": " # responseBody # ".");
        };
      };
    };
  };

  /// Chat completion using Groq API
  ///
  /// @param apiKey - The Groq API key
  /// @param messages - Array of chat messages
  /// @param model - Model name
  /// @param temperature - Optional temperature setting (0.0-1.0)
  /// @param maxTokens - Optional maximum tokens in response
  /// @returns Result with assistant's response or error message
  private func chatCompletion(
    apiKey : Text,
    messages : [ChatMessage],
    model : Text,
    temperature : ?Float,
    maxTokens : ?Nat,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    let request : ChatCompletionRequest = {
      model;
      messages;
      temperature;
      max_tokens = maxTokens;
      top_p = null;
      stream = ?false; // Always false for simplicity
    };

    let requestBody = serializeChatCompletionRequest(request);
    let url = GROQ_API_BASE_URL # "/chat/completions";

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # apiKey },
      { name = "Content-Type"; value = "application/json" },
    ];

    // Make the HTTP POST request
    let httpResult = await HttpWrapper.post(url, headers, requestBody);

    switch (httpResult) {
      case (#err(error)) {
        #err("HTTP request failed: " # error # ".");
      };
      case (#ok((status, responseBody))) {
        if (status == 200) {
          // Parse successful response
          parseGroqResponse(responseBody);
        } else {
          // Return error with status and response details
          #err("Groq API returned status " # Nat.toText(status) # ": " # responseBody # ".");
        };
      };
    };
  };

  // ============================================
  // Public Functions
  // ============================================

  /// Generate reasoning response using Groq Responses API
  ///
  /// Returns a variant indicating whether the LLM:
  /// - Returned a text response (#textResponse)
  /// - Wants to call one or more tools (#toolCalls)
  /// - Encountered an error (#error)
  ///
  /// @param apiKey - The Groq API key
  /// @param input - Array of input messages with role and content
  /// @param model - Model name (should support reasoning)
  /// @param trackId - Tracking identifier for attribution and usage monitoring
  /// @param instructions - Optional system instructions
  /// @param temperature - Optional temperature setting (0.0-2.0)
  /// @param tools - Optional tools for function calling
  /// @returns ReasonWithToolsResult indicating text response, tool calls, or error
  public func reason(
    apiKey : Text,
    input : ResponseInput,
    model : Text,
    trackId : TrackId,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[Tool],
  ) : async ReasonWithToolsResult {
    assert Text.trim(apiKey, #char ' ') != "";
    assert input.size() > 0;
    assert Text.trim(model, #char ' ') != "";

    let inputData : ResponseInput = input;

    // Create user key from trackId
    let userKey = switch (trackId) {
      case (#workspace(id)) { Nat.toText(id) };
      case (#workspaceAgent(wsId, agId)) {
        Nat.toText(wsId) # "_" # Nat.toText(agId);
      };
    };

    await createResponse(
      apiKey,
      inputData,
      model,
      instructions,
      temperature,
      null, // maxOutputTokens
      null, // reasoning always null
      tools,
      null, // no tool choice
      ?userKey, // user key for identification
    );
  };

  /// Simple chat function with just message content
  ///
  /// @param apiKey - The Groq API key
  /// @param userMessage - The user's message
  /// @param model - Optional model name
  /// @returns Result with assistant's response or error message
  public func chat(
    apiKey : Text,
    userMessage : Text,
    model : Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    assert Text.trim(apiKey, #char ' ') != "";
    assert Text.trim(userMessage, #char ' ') != "";
    assert Text.trim(model, #char ' ') != "";

    let messages : [ChatMessage] = [{ role = #user; content = userMessage }];

    await chatCompletion(apiKey, messages, model, null, null);
  };
};
