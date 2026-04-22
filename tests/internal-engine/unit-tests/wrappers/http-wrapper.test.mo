/// HTTP Wrapper — Unit Tests
///
/// Covers the three pure helper functions:
///   • validateAndNormalizeUrl   — ensures a valid http/s scheme
///   • calculateRequestBytes     — sums URL + header + body sizes
///   • calculateHttpOutcallCycles — applies the IC pricing formula

import { test; expect } "mo:test";
import Text "mo:core/Text";
import HttpWrapper "../../../../src/internal-engine/wrappers/http-wrapper";

// ─────────────────────────────────────────────────────────────────
// validateAndNormalizeUrl
// ─────────────────────────────────────────────────────────────────

test(
  "validateAndNormalizeUrl: https:// prefix is unchanged",
  func() {
    let url = "https://example.com/path";
    expect.text(HttpWrapper.validateAndNormalizeUrl(url)).equal(url);
  },
);

test(
  "validateAndNormalizeUrl: http:// prefix is unchanged",
  func() {
    let url = "http://example.com/path";
    expect.text(HttpWrapper.validateAndNormalizeUrl(url)).equal(url);
  },
);

test(
  "validateAndNormalizeUrl: no scheme gets https:// prepended",
  func() {
    expect.text(HttpWrapper.validateAndNormalizeUrl("example.com/api")).equal("https://example.com/api");
  },
);

test(
  "validateAndNormalizeUrl: bare domain gets https:// prepended",
  func() {
    expect.text(HttpWrapper.validateAndNormalizeUrl("api.openrouter.ai")).equal("https://api.openrouter.ai");
  },
);

test(
  "validateAndNormalizeUrl: empty string becomes https://",
  func() {
    expect.text(HttpWrapper.validateAndNormalizeUrl("")).equal("https://");
  },
);

test(
  "validateAndNormalizeUrl: result always starts with http",
  func() {
    let result = HttpWrapper.validateAndNormalizeUrl("no-scheme.example.com");
    expect.bool(
      Text.startsWith(result, #text "http://") or Text.startsWith(result, #text "https://")
    ).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// calculateRequestBytes
// ─────────────────────────────────────────────────────────────────

test(
  "calculateRequestBytes: URL only with no headers and no body",
  func() {
    // "abc" = 3 bytes
    expect.nat(HttpWrapper.calculateRequestBytes("abc", [], null)).equal(3);
  },
);

test(
  "calculateRequestBytes: empty URL, no headers, no body returns 0",
  func() {
    expect.nat(HttpWrapper.calculateRequestBytes("", [], null)).equal(0);
  },
);

test(
  "calculateRequestBytes: URL + single header adds name and value lengths",
  func() {
    // "abc"=3, header name "X"=1, header value "Y"=1 → 5
    let headers = [{ name = "X"; value = "Y" }];
    expect.nat(HttpWrapper.calculateRequestBytes("abc", headers, null)).equal(5);
  },
);

test(
  "calculateRequestBytes: URL + multiple headers sums all name+value lengths",
  func() {
    // url "ab"=2, header1 name "H1"=2 value "V1"=2, header2 name "H2"=2 value "V2"=2 → 10
    let headers = [{ name = "H1"; value = "V1" }, { name = "H2"; value = "V2" }];
    expect.nat(HttpWrapper.calculateRequestBytes("ab", headers, null)).equal(10);
  },
);

test(
  "calculateRequestBytes: URL + body blob adds body size",
  func() {
    // url "abc"=3, body "hello"=5 → 8
    let body = Text.encodeUtf8("hello");
    expect.nat(HttpWrapper.calculateRequestBytes("abc", [], ?body)).equal(8);
  },
);

test(
  "calculateRequestBytes: URL + headers + body sums everything",
  func() {
    // url "url"=3, header name "K"=1 value "V"=1, body "hi"=2 → 7
    let headers = [{ name = "K"; value = "V" }];
    let body = Text.encodeUtf8("hi");
    expect.nat(HttpWrapper.calculateRequestBytes("url", headers, ?body)).equal(7);
  },
);

test(
  "calculateRequestBytes: larger URL returns larger byte count",
  func() {
    let short = HttpWrapper.calculateRequestBytes("abc", [], null);
    let long = HttpWrapper.calculateRequestBytes("abcdefghij", [], null);
    expect.bool(long > short).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// calculateHttpOutcallCycles
// ─────────────────────────────────────────────────────────────────

test(
  "calculateHttpOutcallCycles: always returns a positive value",
  func() {
    expect.bool(HttpWrapper.calculateHttpOutcallCycles(0) > 0).isTrue();
  },
);

test(
  "calculateHttpOutcallCycles: larger request bytes → more cycles",
  func() {
    let baseline = HttpWrapper.calculateHttpOutcallCycles(0);
    let larger = HttpWrapper.calculateHttpOutcallCycles(1000);
    expect.bool(larger > baseline).isTrue();
  },
);

test(
  "calculateHttpOutcallCycles: 0 bytes matches expected IC formula result",
  func() {
    // n = 13
    // baseFee  = (3_000_000 + 60_000 * 13) * 13 = 3_780_000 * 13 = 49_140_000
    // sizeFee  = (400 * 0 + 800 * 2_000_000) * 13 = 1_600_000_000 * 13 = 20_800_000_000
    // total    = 20_849_140_000
    // × 1.5    = 31_273_710_000
    expect.nat(HttpWrapper.calculateHttpOutcallCycles(0)).equal(31_273_710_000);
  },
);

test(
  "calculateHttpOutcallCycles: each extra byte adds fixed cycle increment",
  func() {
    // Per byte: 400 * n * 1.5 = 400 * 13 * 1.5 = 7_800 cycles per byte
    let base = HttpWrapper.calculateHttpOutcallCycles(0);
    let plus100 = HttpWrapper.calculateHttpOutcallCycles(100);
    expect.nat(plus100 - base).equal(780_000);
  },
);
