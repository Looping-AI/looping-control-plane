import Text "mo:core/Text";
import Array "mo:core/Array";
import Result "mo:core/Result";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Bool "mo:core/Bool";
import HttpWrapper "./http-wrapper";

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

  /// Serialize a ChatMessage to JSON string
  private func serializeMessage(message : ChatMessage) : Text {
    "{\"role\": \"" # roleToString(message.role) # "\", \"content\": \"" # escapeJsonString(message.content) # "\"}";
  };

  /// Escape special characters for JSON string
  private func escapeJsonString(input : Text) : Text {
    // Simple escape for quotes and newlines - could be more comprehensive
    let withQuotes = replaceText(input, "\"", "\\\"");
    let withNewlines = replaceText(withQuotes, "\n", "\\n");
    let withTabs = replaceText(withNewlines, "\t", "\\t");
    withTabs;
  };

  /// Helper function to join array elements with separator since Text.join doesn't exist
  private func joinArrayWithSeparator(arr : [Text], sep : Text) : Text {
    if (arr.size() == 0) {
      return "";
    };
    if (arr.size() == 1) {
      return arr[0];
    };
    var result = arr[0];
    var i = 1;
    while (i < arr.size()) {
      result := result # sep # arr[i];
      i += 1;
    };
    result;
  };

  /// Helper function to replace text since Text.replace doesn't exist in mo:core
  private func replaceText(input : Text, old : Text, new : Text) : Text {
    // Simple implementation - can be improved for better performance
    let oldSize = old.size();
    if (oldSize == 0) { return input };

    var result = "";
    let inputArray = Text.toArray(input);
    var i = 0;

    while (i < inputArray.size()) {
      if (i + oldSize <= inputArray.size()) {
        let potential = Text.fromArray(Array.tabulate<Char>(oldSize, func(j) { inputArray[i + j] }));
        if (potential == old) {
          result #= new;
          i += oldSize;
        } else {
          result #= Text.fromArray([inputArray[i]]);
          i += 1;
        };
      } else {
        result #= Text.fromArray([inputArray[i]]);
        i += 1;
      };
    };
    result;
  };

  /// Serialize ChatCompletionRequest to JSON string
  private func serializeRequest(request : ChatCompletionRequest) : Text {
    let messagesJson = joinArrayWithSeparator(Array.map<ChatMessage, Text>(request.messages, serializeMessage), ",");

    var json = "{\"model\": \"" # request.model # "\", \"messages\": [" # messagesJson # "]";

    switch (request.temperature) {
      case (?temp) { json #= ", \"temperature\": " # Float.toText(temp) };
      case (null) {};
    };

    switch (request.max_tokens) {
      case (?tokens) { json #= ", \"max_tokens\": " # Nat.toText(tokens) };
      case (null) {};
    };

    switch (request.top_p) {
      case (?p) { json #= ", \"top_p\": " # Float.toText(p) };
      case (null) {};
    };

    switch (request.stream) {
      case (?s) { json #= ", \"stream\": " # Bool.toText(s) };
      case (null) {};
    };

    json # "}";
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
  /// This is a simplified JSON parser that looks for the content field
  /// in the first choice. In production, you'd want more robust JSON parsing.
  ///
  /// @param responseBody - Raw JSON response from Groq API
  /// @returns Result with extracted content or error message
  private func parseGroqResponse(responseBody : Text) : Result.Result<Text, Text> {
    // Simple string-based parsing - look for first "content" field in choices
    // This is fragile but works for the expected Groq response format

    // Look for "choices":[{"message":{"content":"..."}
    let searchPattern = "\"content\":\"";
    switch (findSubstring(responseBody, searchPattern)) {
      case (null) {
        #err("Could not find content in response: " # responseBody);
      };
      case (?startIndex) {
        let afterContent = dropText(responseBody, startIndex + searchPattern.size());

        // Find the closing quote (handling escaped quotes is complex, so we'll do simple approach)
        switch (findClosingQuote(afterContent, 0)) {
          case (null) {
            #err("Could not parse content from response");
          };
          case (?endIndex) {
            let content = takeText(afterContent, endIndex);
            let unescaped = unescapeJsonString(content);
            #ok(unescaped);
          };
        };
      };
    };
  };

  /// Find the index of the closing quote for a JSON string value
  /// This is a simplified approach that doesn't handle all edge cases
  private func findClosingQuote(text : Text, startPos : Nat) : ?Nat {
    let chars = Text.toArray(text);
    var i = startPos;
    var escaped = false;

    while (i < chars.size()) {
      let char = chars[i];

      if (escaped) {
        escaped := false;
      } else if (char == '\\') {
        escaped := true;
      } else if (char == '\"') {
        return ?i;
      };

      i += 1;
    };

    null;
  };

  /// Basic unescape for JSON strings
  private func unescapeJsonString(input : Text) : Text {
    let withQuotes = replaceText(input, "\\\"", "\"");
    let withNewlines = replaceText(withQuotes, "\\n", "\n");
    let withTabs = replaceText(withNewlines, "\\t", "\t");
    withTabs;
  };

  /// Find substring in text and return index
  private func findSubstring(text : Text, pattern : Text) : ?Nat {
    let textArray = Text.toArray(text);
    let patternArray = Text.toArray(pattern);
    let patternSize = patternArray.size();

    if (patternSize == 0) { return ?0 };
    if (textArray.size() < patternSize) { return null };

    var i = 0;
    while (i + patternSize <= textArray.size()) {
      var match = true;
      var j = 0;
      while (j < patternSize and match) {
        if (textArray[i + j] != patternArray[j]) {
          match := false;
        };
        j += 1;
      };
      if (match) {
        return ?i;
      };
      i += 1;
    };
    null;
  };

  /// Drop the first n characters from text
  private func dropText(text : Text, n : Nat) : Text {
    let textArray = Text.toArray(text);
    if (n >= textArray.size()) {
      return "";
    };
    let remainingSize = Nat.sub(textArray.size(), n);
    Text.fromArray(Array.tabulate<Char>(remainingSize, func(i) { textArray[n + i] }));
  };

  /// Take the first n characters from text
  private func takeText(text : Text, n : Nat) : Text {
    let textArray = Text.toArray(text);
    let size = if (n < textArray.size()) n else textArray.size();
    Text.fromArray(Array.tabulate<Char>(size, func(i) { textArray[i] }));
  };
};
