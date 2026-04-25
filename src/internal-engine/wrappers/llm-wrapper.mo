import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import List "mo:core/List";
import Json "mo:json";
import { str; float; bool; obj; arr } "mo:json";
import HttpWrapper "./http-wrapper";
import ExecutionTypes "../execution-types";

module {

  // ── Constants ──────────────────────────────────────────────────────

  private let OPENROUTER_API_BASE_URL : Text = "https://openrouter.ai/api/v1";

  // ── Types ──────────────────────────────────────────────────────────

  public type FunctionDef = {
    name : Text;
    description : ?Text;
    parameters : ?Text; // JSON schema as string
  };

  public type Tool = {
    tool_type : Text; // "function"
    function_ : FunctionDef;
  };

  public type ToolCall = {
    callId : Text;
    toolName : Text;
    arguments : Text; // JSON string
  };

  /// A single item in the Responses API `input` array.
  /// Covers regular messages, echoed function calls from previous
  /// LLM responses, and tool execution results.
  public type InputItem = {
    #message : { role : ExecutionTypes.ChatRole; content : Text };
    #functionCall : { callId : Text; name : Text; arguments : Text };
    #functionCallOutput : { callId : Text; output : Text };
  };

  public type ReasonResult = {
    #ok : {
      #textResponse : { content : Text; thinking : ?Text };
      #toolCalls : [ToolCall];
    };
    #err : Text;
  };

  public type ReasonUsage = {
    inputTokens : Nat;
    outputTokens : Nat;
    cost : ?Float;
  };

  public type ReasonResponse = {
    result : ReasonResult;
    usage : ?ReasonUsage;
    model : Text;
  };

  // ── Conversion helpers ─────────────────────────────────────────────

  /// Convert initial ChatMessages from the envelope into InputItems.
  public func chatMessagesToInput(messages : [ExecutionTypes.ChatMessage]) : [InputItem] {
    Array.map<ExecutionTypes.ChatMessage, InputItem>(messages, func(msg) { #message(msg) });
  };

  /// Build InputItems for a completed tool round: the echoed function calls
  /// from the LLM response followed by the execution results.
  public func toolRoundToInput(calls : [ToolCall], results : [{ callId : Text; output : Text; success : Bool }]) : [InputItem] {
    let items = List.empty<InputItem>();

    for (call in calls.vals()) {
      List.add(items, #functionCall({ callId = call.callId; name = call.toolName; arguments = call.arguments }));
    };

    for (r in results.vals()) {
      List.add(items, #functionCallOutput({ callId = r.callId; output = r.output }));
    };

    List.toArray(items);
  };

  // ── Serialization helpers ──────────────────────────────────────────

  private func chatRoleToString(role : ExecutionTypes.ChatRole) : Text {
    switch (role) {
      case (#user) { "user" };
      case (#assistant) { "assistant" };
      case (#system_) { "system" };
      case (#developer) { "developer" };
    };
  };

  private func inputItemToJson(item : InputItem) : Json.Json {
    switch (item) {
      case (#message({ role; content })) {
        obj([
          ("role", str(chatRoleToString(role))),
          ("content", str(content)),
        ]);
      };
      case (#functionCall({ callId; name; arguments })) {
        obj([
          ("type", str("function_call")),
          ("call_id", str(callId)),
          ("name", str(name)),
          ("arguments", str(arguments)),
        ]);
      };
      case (#functionCallOutput({ callId; output })) {
        obj([
          ("type", str("function_call_output")),
          ("call_id", str(callId)),
          ("output", str(output)),
        ]);
      };
    };
  };

  private func toolToJson(tool : Tool) : Json.Json {
    let fields = List.empty<(Text, Json.Json)>();
    List.add(fields, ("type", str(tool.tool_type)));
    List.add(fields, ("name", str(tool.function_.name)));

    switch (tool.function_.description) {
      case (?desc) { List.add(fields, ("description", str(desc))) };
      case (null) {};
    };

    switch (tool.function_.parameters) {
      case (?params) {
        switch (Json.parse(params)) {
          case (#ok(paramJson)) {
            List.add(fields, ("parameters", paramJson));
          };
          case (#err(_)) {};
        };
      };
      case (null) {};
    };

    obj(List.toArray(fields));
  };

  private func serializeRequest(
    input : [InputItem],
    model : Text,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[Tool],
  ) : Text {
    let fields = List.empty<(Text, Json.Json)>();

    List.add(fields, ("input", arr(Array.map<InputItem, Json.Json>(input, inputItemToJson))));
    List.add(fields, ("model", str(model)));

    switch (instructions) {
      case (?inst) { List.add(fields, ("instructions", str(inst))) };
      case (null) {};
    };

    switch (temperature) {
      case (?temp) { List.add(fields, ("temperature", float(temp))) };
      case (null) {};
    };

    switch (tools) {
      case (?t) {
        List.add(fields, ("tools", arr(Array.map<Tool, Json.Json>(t, toolToJson))));
      };
      case (null) {};
    };

    List.add(fields, ("store", bool(false)));
    List.add(fields, ("stream", bool(false)));
    List.add(fields, ("reasoning", obj([("effort", str("high")), ("summary", str("auto"))])));

    Json.stringify(obj(List.toArray(fields)), null);
  };

  // ── Response parsing ───────────────────────────────────────────────

  private func parseUsage(json : Json.Json) : ?ReasonUsage {
    switch (Json.get(json, "usage")) {
      case (null) { null };
      case (?usageJson) {
        let inputOpt = switch (Json.get(usageJson, "input_tokens")) {
          case (?#number(#int(n))) { ?Int.abs(n) };
          case (?#number(#float(f))) { ?Int.abs(Float.toInt(f)) };
          case (_) { null };
        };
        let outputOpt = switch (Json.get(usageJson, "output_tokens")) {
          case (?#number(#int(n))) { ?Int.abs(n) };
          case (?#number(#float(f))) { ?Int.abs(Float.toInt(f)) };
          case (_) { null };
        };
        let cost = switch (Json.get(usageJson, "cost")) {
          case (?#number(#float(f))) { ?f };
          case (?#number(#int(i))) { ?Float.fromInt(i) };
          case (_) { null };
        };
        switch (inputOpt, outputOpt) {
          case (?inputTokens, ?outputTokens) {
            ?{ inputTokens; outputTokens; cost };
          };
          case (_) { null };
        };
      };
    };
  };

  private func parseModel(json : Json.Json) : Text {
    switch (Json.get(json, "model")) {
      case (?#string(m)) { m };
      case (_) { "unknown" };
    };
  };

  private func parseResponseBody(responseBody : Text) : ReasonResponse {
    switch (Json.parse(responseBody)) {
      case (#err(error)) {
        {
          result = #err("Failed to parse JSON response: " # debug_show error # ".");
          usage = null;
          model = "unknown";
        };
      };
      case (#ok(json)) {
        let usage = parseUsage(json);
        let model = parseModel(json);

        let result : ReasonResult = switch (Json.get(json, "output")) {
          case (null) {
            #err("Could not find output array in response.");
          };
          case (?outputArrayJson) {
            switch (outputArrayJson) {
              case (#array(outputs)) {
                parseOutputArray(outputs);
              };
              case (_) {
                #err("Output field is not an array.");
              };
            };
          };
        };

        { result; usage; model };
      };
    };
  };

  private func parseOutputArray(outputs : [Json.Json]) : ReasonResult {
    let toolCallsList = List.empty<ToolCall>();

    for (outputJson in outputs.vals()) {
      switch (Json.get(outputJson, "type")) {
        case (?#string("function_call")) {
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
              List.add(toolCallsList, { callId; toolName = name; arguments = args });
            };
            case (_) {};
          };
        };
        case (_) {};
      };
    };

    let toolCallsArray = List.toArray(toolCallsList);
    if (toolCallsArray.size() > 0) {
      return #ok(#toolCalls(toolCallsArray));
    };

    var thinkingOpt : ?Text = null;
    for (outputJson in outputs.vals()) {
      switch (Json.get(outputJson, "type")) {
        case (?#string("reasoning")) {
          switch (Json.get(outputJson, "summary[0].text")) {
            case (?#string(t)) { thinkingOpt := ?t };
            case (_) {};
          };
        };
        case (_) {};
      };
    };

    for (outputJson in outputs.vals()) {
      switch (Json.get(outputJson, "type")) {
        case (?#string("message")) {
          switch (Json.get(outputJson, "content[0].text")) {
            case (?#string(content)) {
              return #ok(#textResponse({ content; thinking = thinkingOpt }));
            };
            case (_) {};
          };
        };
        case (_) {};
      };
    };

    #err("Could not find message output or tool calls in response.");
  };

  // ── Public API ─────────────────────────────────────────────────────

  public func reason(
    apiKey : Text,
    input : [InputItem],
    model : Text,
    instructions : ?Text,
    temperature : ?Float,
    tools : ?[Tool],
  ) : async ReasonResponse {
    assert Text.trim(apiKey, #char ' ') != "";
    assert input.size() > 0;
    assert Text.trim(model, #char ' ') != "";

    let requestBody = serializeRequest(
      input,
      model,
      instructions,
      temperature,
      tools,
    );

    let url = OPENROUTER_API_BASE_URL # "/responses";

    let headers : [HttpWrapper.HttpHeader] = [
      { name = "Authorization"; value = "Bearer " # apiKey },
      { name = "Content-Type"; value = "application/json" },
      { name = "HTTP-Referer"; value = "https://loopingai.app" },
      { name = "X-Title"; value = "Looping AI" },
    ];

    let httpResult = await HttpWrapper.post(url, headers, requestBody);

    switch (httpResult) {
      case (#err(error)) {
        {
          result = #err("HTTP request failed: " # error # ".");
          usage = null;
          model = "unknown";
        };
      };
      case (#ok((status, responseBody))) {
        if (status == 200) {
          parseResponseBody(responseBody);
        } else {
          {
            result = #err("OpenRouter Responses API returned status " # Nat.toText(status) # ": " # responseBody # ".");
            usage = null;
            model;
          };
        };
      };
    };
  };

};
