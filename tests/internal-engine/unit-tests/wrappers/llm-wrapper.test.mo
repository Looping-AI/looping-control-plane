/// LLM Wrapper — Unit Tests
///
/// Covers the two pure conversion helpers:
///   • chatMessagesToInput — maps ChatMessage[] → InputItem[] (#message variants)
///   • toolRoundToInput    — interleaves tool calls and their results as InputItems,
///                           #functionCall items first, then #functionCallOutput items

import { test; expect } "mo:test";
import LlmWrapper "../../../../src/internal-engine/wrappers/llm-wrapper";
import ExecutionTypes "../../../../src/internal-engine/execution-types";

// ─────────────────────────────────────────────────────────────────
// chatMessagesToInput
// ─────────────────────────────────────────────────────────────────

test(
  "chatMessagesToInput: empty messages returns empty array",
  func() {
    expect.nat(LlmWrapper.chatMessagesToInput([]).size()).equal(0);
  },
);

test(
  "chatMessagesToInput: single message produces one InputItem",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [{
      role = #user;
      content = "hello";
    }];
    expect.nat(LlmWrapper.chatMessagesToInput(msgs).size()).equal(1);
  },
);

test(
  "chatMessagesToInput: item is a #message variant",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [{ role = #user; content = "hi" }];
    let items = LlmWrapper.chatMessagesToInput(msgs);
    switch (items[0]) {
      case (#message(_)) {}; // expected
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "chatMessagesToInput: #user role is preserved",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [{ role = #user; content = "q" }];
    let items = LlmWrapper.chatMessagesToInput(msgs);
    switch (items[0]) {
      case (#message({ role; content = _ })) {
        switch (role) {
          case (#user) {};
          case (_) { expect.bool(false).isTrue() };
        };
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "chatMessagesToInput: #assistant role is preserved",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [{
      role = #assistant;
      content = "a";
    }];
    let items = LlmWrapper.chatMessagesToInput(msgs);
    switch (items[0]) {
      case (#message({ role; content = _ })) {
        switch (role) {
          case (#assistant) {};
          case (_) { expect.bool(false).isTrue() };
        };
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "chatMessagesToInput: content is preserved",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [{
      role = #user;
      content = "exact content";
    }];
    let items = LlmWrapper.chatMessagesToInput(msgs);
    switch (items[0]) {
      case (#message({ role = _; content })) {
        expect.text(content).equal("exact content");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "chatMessagesToInput: multiple messages produce same count",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [
      { role = #user; content = "msg1" },
      { role = #assistant; content = "msg2" },
      { role = #user; content = "msg3" },
    ];
    expect.nat(LlmWrapper.chatMessagesToInput(msgs).size()).equal(3);
  },
);

test(
  "chatMessagesToInput: multiple messages preserve order",
  func() {
    let msgs : [ExecutionTypes.ChatMessage] = [
      { role = #user; content = "first" },
      { role = #assistant; content = "second" },
    ];
    let items = LlmWrapper.chatMessagesToInput(msgs);
    switch (items[0]) {
      case (#message({ role = _; content })) {
        expect.text(content).equal("first");
      };
      case (_) { expect.bool(false).isTrue() };
    };
    switch (items[1]) {
      case (#message({ role = _; content })) {
        expect.text(content).equal("second");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

// ─────────────────────────────────────────────────────────────────
// toolRoundToInput
// ─────────────────────────────────────────────────────────────────

test(
  "toolRoundToInput: empty calls and results returns empty array",
  func() {
    expect.nat(LlmWrapper.toolRoundToInput([], []).size()).equal(0);
  },
);

test(
  "toolRoundToInput: one call and no results returns one item",
  func() {
    let calls = [{ callId = "c1"; toolName = "my_tool"; arguments = "{}" }];
    expect.nat(LlmWrapper.toolRoundToInput(calls, []).size()).equal(1);
  },
);

test(
  "toolRoundToInput: no calls and one result returns one item",
  func() {
    let results = [{ callId = "c1"; output = "ok"; success = true }];
    expect.nat(LlmWrapper.toolRoundToInput([], results).size()).equal(1);
  },
);

test(
  "toolRoundToInput: N calls + M results → N+M items total",
  func() {
    let calls = [
      { callId = "c1"; toolName = "tool_a"; arguments = "{}" },
      { callId = "c2"; toolName = "tool_b"; arguments = "{}" },
    ];
    let results = [
      { callId = "c1"; output = "result_a"; success = true },
      { callId = "c2"; output = "result_b"; success = false },
    ];
    expect.nat(LlmWrapper.toolRoundToInput(calls, results).size()).equal(4);
  },
);

test(
  "toolRoundToInput: first item is #functionCall",
  func() {
    let calls = [{ callId = "c1"; toolName = "list_agents"; arguments = "{}" }];
    let results = [{ callId = "c1"; output = "[]"; success = true }];
    let items = LlmWrapper.toolRoundToInput(calls, results);
    switch (items[0]) {
      case (#functionCall(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCall item after calls is #functionCallOutput",
  func() {
    let calls = [{ callId = "c1"; toolName = "list_agents"; arguments = "{}" }];
    let results = [{ callId = "c1"; output = "[]"; success = true }];
    let items = LlmWrapper.toolRoundToInput(calls, results);
    switch (items[1]) {
      case (#functionCallOutput(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: all #functionCall items precede all #functionCallOutput items",
  func() {
    let calls = [
      { callId = "c1"; toolName = "tool_a"; arguments = "{}" },
      { callId = "c2"; toolName = "tool_b"; arguments = "{}" },
    ];
    let results = [
      { callId = "c1"; output = "r1"; success = true },
      { callId = "c2"; output = "r2"; success = true },
    ];
    let items = LlmWrapper.toolRoundToInput(calls, results);
    // items[0] and items[1] should be #functionCall
    switch (items[0]) {
      case (#functionCall(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
    switch (items[1]) {
      case (#functionCall(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
    // items[2] and items[3] should be #functionCallOutput
    switch (items[2]) {
      case (#functionCallOutput(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
    switch (items[3]) {
      case (#functionCallOutput(_)) {};
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCall preserves callId",
  func() {
    let calls = [{
      callId = "my-call-id";
      toolName = "get_workspace";
      arguments = "{}";
    }];
    let items = LlmWrapper.toolRoundToInput(calls, []);
    switch (items[0]) {
      case (#functionCall({ callId; name = _; arguments = _ })) {
        expect.text(callId).equal("my-call-id");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCall preserves toolName as name",
  func() {
    let calls = [{ callId = "c1"; toolName = "get_workspace"; arguments = "{}" }];
    let items = LlmWrapper.toolRoundToInput(calls, []);
    switch (items[0]) {
      case (#functionCall({ callId = _; name; arguments = _ })) {
        expect.text(name).equal("get_workspace");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCall preserves arguments",
  func() {
    let calls = [{
      callId = "c1";
      toolName = "my_tool";
      arguments = "{\"n\":42}";
    }];
    let items = LlmWrapper.toolRoundToInput(calls, []);
    switch (items[0]) {
      case (#functionCall({ callId = _; name = _; arguments })) {
        expect.text(arguments).equal("{\"n\":42}");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCallOutput preserves callId",
  func() {
    let results = [{ callId = "out-id"; output = "data"; success = true }];
    let items = LlmWrapper.toolRoundToInput([], results);
    switch (items[0]) {
      case (#functionCallOutput({ callId; output = _ })) {
        expect.text(callId).equal("out-id");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);

test(
  "toolRoundToInput: #functionCallOutput preserves output",
  func() {
    let results = [{
      callId = "c1";
      output = "the output string";
      success = true;
    }];
    let items = LlmWrapper.toolRoundToInput([], results);
    switch (items[0]) {
      case (#functionCallOutput({ callId = _; output })) {
        expect.text(output).equal("the output string");
      };
      case (_) { expect.bool(false).isTrue() };
    };
  },
);
