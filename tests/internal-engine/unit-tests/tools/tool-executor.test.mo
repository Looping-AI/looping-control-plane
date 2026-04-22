/// Tool Executor — Unit Tests
///
/// Covers the two pure/synchronous helpers:
///   • formatResultsForLlm — maps ToolResult → {callId, output, success}
///   • injectNonce          — injects envelopeNonce into a JSON body string

import { test; expect } "mo:test";
import Text "mo:core/Text";
import ToolExecutor "../../../../src/internal-engine/tools/tool-executor";

// ─────────────────────────────────────────────────────────────────
// formatResultsForLlm
// ─────────────────────────────────────────────────────────────────

test(
  "formatResultsForLlm: empty input returns empty array",
  func() {
    expect.nat(ToolExecutor.formatResultsForLlm([]).size()).equal(0);
  },
);

test(
  "formatResultsForLlm: success result has success=true",
  func() {
    let results = [{
      callId = "c1";
      result = #success("the data");
      durationMs = 10;
    }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.bool(formatted[0].success).isTrue();
  },
);

test(
  "formatResultsForLlm: success result output equals the data string",
  func() {
    let results = [{
      callId = "c1";
      result = #success("the data");
      durationMs = 10;
    }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.text(formatted[0].output).equal("the data");
  },
);

test(
  "formatResultsForLlm: success result preserves callId",
  func() {
    let results = [{
      callId = "call-abc";
      result = #success("x");
      durationMs = 0;
    }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.text(formatted[0].callId).equal("call-abc");
  },
);

test(
  "formatResultsForLlm: error result has success=false",
  func() {
    let results = [{
      callId = "c2";
      result = #error("something went wrong");
      durationMs = 5;
    }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.bool(formatted[0].success).isFalse();
  },
);

test(
  "formatResultsForLlm: error result output is prefixed with 'Error: '",
  func() {
    let results = [{ callId = "c2"; result = #error("timeout"); durationMs = 5 }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.text(formatted[0].output).equal("Error: timeout");
  },
);

test(
  "formatResultsForLlm: error result preserves callId",
  func() {
    let results = [{
      callId = "err-xyz";
      result = #error("oops");
      durationMs = 0;
    }];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.text(formatted[0].callId).equal("err-xyz");
  },
);

test(
  "formatResultsForLlm: output count matches input count",
  func() {
    let results = [
      { callId = "c1"; result = #success("a"); durationMs = 1 },
      { callId = "c2"; result = #error("b"); durationMs = 2 },
      { callId = "c3"; result = #success("c"); durationMs = 3 },
    ];
    expect.nat(ToolExecutor.formatResultsForLlm(results).size()).equal(3);
  },
);

test(
  "formatResultsForLlm: output order matches input order",
  func() {
    let results = [
      { callId = "first"; result = #success("1"); durationMs = 0 },
      { callId = "second"; result = #error("2"); durationMs = 0 },
    ];
    let formatted = ToolExecutor.formatResultsForLlm(results);
    expect.text(formatted[0].callId).equal("first");
    expect.text(formatted[1].callId).equal("second");
  },
);

// ─────────────────────────────────────────────────────────────────
// injectNonce
// ─────────────────────────────────────────────────────────────────

test(
  "injectNonce: result contains envelopeNonce key",
  func() {
    let result = ToolExecutor.injectNonce("{}", "nonce-123");
    expect.bool(Text.contains(result, #text "envelopeNonce")).isTrue();
  },
);

test(
  "injectNonce: result contains the nonce value",
  func() {
    let result = ToolExecutor.injectNonce("{}", "my-secret-nonce");
    expect.bool(Text.contains(result, #text "my-secret-nonce")).isTrue();
  },
);

test(
  "injectNonce: valid JSON object - original fields are preserved",
  func() {
    let result = ToolExecutor.injectNonce("{\"foo\":\"bar\"}", "n1");
    expect.bool(Text.contains(result, #text "foo")).isTrue();
    expect.bool(Text.contains(result, #text "bar")).isTrue();
  },
);

test(
  "injectNonce: valid JSON object - nonce and original fields both present",
  func() {
    let result = ToolExecutor.injectNonce("{\"key\":\"val\"}", "abc");
    expect.bool(Text.contains(result, #text "envelopeNonce")).isTrue();
    expect.bool(Text.contains(result, #text "key")).isTrue();
  },
);

test(
  "injectNonce: invalid JSON body - result still contains nonce",
  func() {
    let result = ToolExecutor.injectNonce("not-valid-json", "nonce-xyz");
    expect.bool(Text.contains(result, #text "envelopeNonce")).isTrue();
    expect.bool(Text.contains(result, #text "nonce-xyz")).isTrue();
  },
);

test(
  "injectNonce: empty string body treated as invalid JSON - returns nonce-only object",
  func() {
    let result = ToolExecutor.injectNonce("", "nonce-abc");
    expect.bool(Text.contains(result, #text "envelopeNonce")).isTrue();
    expect.bool(Text.contains(result, #text "nonce-abc")).isTrue();
  },
);

test(
  "injectNonce: JSON array body treated as invalid - returns nonce-only object",
  func() {
    // The source only handles #object_ — arrays fall through to the fallback
    let result = ToolExecutor.injectNonce("[1,2,3]", "my-nonce");
    expect.bool(Text.contains(result, #text "envelopeNonce")).isTrue();
    expect.bool(Text.contains(result, #text "my-nonce")).isTrue();
  },
);

test(
  "injectNonce: result is a JSON object (starts with {)",
  func() {
    let result = ToolExecutor.injectNonce("{\"x\":1}", "n");
    expect.bool(Text.startsWith(result, #text "{")).isTrue();
  },
);
