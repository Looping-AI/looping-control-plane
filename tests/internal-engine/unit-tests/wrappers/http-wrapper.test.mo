/// HTTP Wrapper — Unit Tests
///
/// Covers the pure helper function:
///   • validateAndNormalizeUrl   — ensures a valid http/s scheme

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
