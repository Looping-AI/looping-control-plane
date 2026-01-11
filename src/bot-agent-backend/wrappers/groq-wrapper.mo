import Text "mo:core/Text";
import Array "mo:core/Array";
import Result "mo:core/Result";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Bool "mo:core/Bool";
import HttpWrapper "./http-wrapper";
import Json "mo:json";
import { str; int; float; bool; obj; arr } "mo:json";

module {
  // ============================================
  // Types for Groq API
  // ============================================

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

  // ============================================
  // Constants
  // ============================================

  /// Groq API base URL
  private let GROQ_API_BASE_URL : Text = "https://api.groq.com/openai/v1";

  /// Default model for Groq
  public let DEFAULT_MODEL : Text = "llama-3.3-70b-versatile";

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

  /// Convert a ChatMessage to JSON
  private func messageToJson(message : ChatMessage) : Json.Json {
    obj([
      ("role", str(roleToString(message.role))),
      ("content", str(message.content)),
    ]);
  };

  /// Serialize ChatCompletionRequest to JSON string
  private func serializeRequest(request : ChatCompletionRequest) : Text {
    let messagesJson = arr(Array.map<ChatMessage, Json.Json>(request.messages, messageToJson));

    // Build request object by conditionally adding fields
    var requestFields : [(Text, Json.Json)] = [
      ("model", str(request.model)),
      ("messages", messagesJson),
    ];

    // Add optional parameters
    switch (request.temperature) {
      case (?temp) {
        requestFields := [
          ("model", str(request.model)),
          ("messages", messagesJson),
          ("temperature", float(temp)),
        ];
      };
      case (null) {
        requestFields := [
          ("model", str(request.model)),
          ("messages", messagesJson),
        ];
      };
    };

    switch (request.max_tokens) {
      case (?tokens) {
        requestFields := Array.tabulate<(Text, Json.Json)>(
          requestFields.size() + 1,
          func(i) {
            if (i < requestFields.size()) {
              requestFields[i];
            } else { ("max_tokens", int(tokens)) };
          },
        );
      };
      case (null) {};
    };

    switch (request.top_p) {
      case (?p) {
        requestFields := Array.tabulate<(Text, Json.Json)>(
          requestFields.size() + 1,
          func(i) {
            if (i < requestFields.size()) {
              requestFields[i];
            } else { ("top_p", float(p)) };
          },
        );
      };
      case (null) {};
    };

    switch (request.stream) {
      case (?s) {
        requestFields := Array.tabulate<(Text, Json.Json)>(
          requestFields.size() + 1,
          func(i) {
            if (i < requestFields.size()) {
              requestFields[i];
            } else { ("stream", bool(s)) };
          },
        );
      };
      case (null) {};
    };

    Json.stringify(obj(requestFields), null);
  };

  // ============================================
  // Main Functions
  // ============================================

  /// Chat completion using Groq API
  ///
  /// @param apiKey - The Groq API key
  /// @param messages - Array of chat messages
  /// @param model - Optional model name (defaults to DEFAULT_MODEL)
  /// @param temperature - Optional temperature setting (0.0-1.0)
  /// @param maxTokens - Optional maximum tokens in response
  /// @returns Result with assistant's response or error message
  public func chatCompletion(
    apiKey : Text,
    messages : [ChatMessage],
    model : ?Text,
    temperature : ?Float,
    maxTokens : ?Nat,
  ) : async {
    #ok : Text;
    #err : Text;
  } {

    if (Text.trim(apiKey, #char ' ') == "") {
      return #err("API key cannot be empty");
    };

    if (messages.size() == 0) {
      return #err("Messages array cannot be empty");
    };

    let requestModel = switch (model) {
      case (?m) { m };
      case (null) { DEFAULT_MODEL };
    };

    let request : ChatCompletionRequest = {
      model = requestModel;
      messages;
      temperature;
      max_tokens = maxTokens;
      top_p = null;
      stream = ?false; // Always false for simplicity
    };

    let requestBody = serializeRequest(request);
    let url = GROQ_API_BASE_URL # "/chat/completions";

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # apiKey },
      { name = "Content-Type"; value = "application/json" },
    ];

    // Make the HTTP POST request
    let httpResult = await HttpWrapper.post(url, headers, requestBody);

    switch (httpResult) {
      case (#err(error)) {
        #err("HTTP request failed: " # error);
      };
      case (#ok(responseBody)) {
        // Simple response parsing - extract content from first choice
        parseGroqResponse(responseBody);
      };
    };
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
    model : ?Text,
  ) : async {
    #ok : Text;
    #err : Text;
  } {

    let messages : [ChatMessage] = [{ role = #user; content = userMessage }];

    await chatCompletion(apiKey, messages, model, null, null);
  };

  /// Parse Groq API response and extract the assistant's message content
  ///
  /// Uses the JSON library for robust parsing
  ///
  /// @param responseBody - Raw JSON response from Groq API
  /// @returns Result with extracted content or error message
  private func parseGroqResponse(responseBody : Text) : Result.Result<Text, Text> {
    switch (Json.parse(responseBody)) {
      case (#err(error)) {
        #err("Failed to parse JSON response: " # debug_show error);
      };
      case (#ok(json)) {
        // Try to get the content from choices[0].message.content
        switch (Json.get(json, "choices[0].message.content")) {
          case (null) {
            #err("Could not find choices[0].message.content in response");
          };
          case (?contentJson) {
            switch (contentJson) {
              case (#string(content)) {
                #ok(content);
              };
              case (_) {
                #err("Content field is not a string");
              };
            };
          };
        };
      };
    };
  };
};
