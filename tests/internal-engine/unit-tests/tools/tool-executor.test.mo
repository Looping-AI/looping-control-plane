/// Tool Executor — Unit Tests
///
/// Covers the pure/synchronous helper:
///   • formatResultsForLlm — maps ToolResult → {callId, output, success}

import { test; expect } "mo:test";
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
