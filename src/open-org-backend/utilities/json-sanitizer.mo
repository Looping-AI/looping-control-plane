/// JSON Sanitizer
/// Handles UTF-16 surrogate pair escape sequences in JSON strings.
///
/// Background: Some APIs (e.g., Slack Web API) encode emoji as JSON `\uXXXX`
/// surrogate pairs (e.g., `\ud83c\udf88` for U+1F388 🎈). The `mo:json` parser
/// traps when it encounters a lone surrogate codepoint because those are not
/// valid Unicode scalar values. This module provides safe conversion of such
/// sequences into valid Unicode characters.

import Text "mo:core/Text";
import Nat32 "mo:core/Nat32";
import Char "mo:core/Char";

module {

  /// Parse a single hex digit character to its Nat32 value (0–15).
  /// Returns null for non-hex characters.
  private func hexCharToNat32(c : Char) : ?Nat32 {
    let n = Char.toNat32(c);
    if (n >= 0x30 and n <= 0x39) { ?(n - 0x30) } // '0'..'9'
    else if (n >= 0x41 and n <= 0x46) { ?(n - 0x41 + 10) } // 'A'..'F'
    else if (n >= 0x61 and n <= 0x66) { ?(n - 0x61 + 10) } // 'a'..'f'
    else { null };
  };

  /// Count consecutive backslashes immediately before `pos` in `chars`.
  /// Used to determine whether the backslash at `pos` is a real JSON escape
  /// character (even number of preceding backslashes) or is itself escaped
  /// (odd number of preceding backslashes).
  private func countPrecedingBackslashes(chars : [Char], pos : Nat) : Nat {
    var count = 0;
    var j = pos;
    var stop = false;
    while (not stop and j > 0) {
      j -= 1;
      if (chars[j] == '\\') { count += 1 } else { stop := true };
    };
    count;
  };

  /// Parse exactly 4 hex characters from an array starting at `offset`.
  /// Returns the 16-bit value as Nat32, or null if any character is invalid.
  private func parseHex4(chars : [Char], offset : Nat) : ?Nat32 {
    if (offset + 4 > chars.size()) return null;
    var result : Nat32 = 0;
    for (i in [0, 1, 2, 3].vals()) {
      switch (hexCharToNat32(chars[offset + i])) {
        case (?d) { result := result * 16 + d };
        case null { return null };
      };
    };
    ?result;
  };

  /// Sanitize a JSON text string so that UTF-16 surrogate-pair escape sequences
  /// (`\uD800`–`\uDFFF`) are converted to the actual Unicode character.
  ///
  /// This function combines valid high+low surrogate pairs into the real Unicode
  /// codepoint and replaces lone surrogates with U+FFFD (replacement character).
  ///
  /// @param input  JSON string potentially containing surrogate pair escape sequences
  /// @returns      Sanitized string with surrogates resolved to valid Unicode
  public func sanitizeJsonSurrogates(input : Text) : Text {
    let chars = Text.toArray(input);
    let len = chars.size();
    var i : Nat = 0;
    var out = "";

    while (i < len) {
      // Look for a backslash-u sequence, but only when the backslash is not
      // itself escaped (i.e., preceded by an even number of backslashes).
      // A sequence like \\uD83C in raw JSON text means a literal backslash
      // followed by the characters uD83C — it must not be treated as \uXXXX.
      if (i + 5 < len and chars[i] == '\\' and chars[i + 1] == 'u' and countPrecedingBackslashes(chars, i) % 2 == 0) {
        switch (parseHex4(chars, i + 2)) {
          case (?cp) {
            // Is this a high surrogate? (0xD800–0xDBFF)
            if (cp >= 0xD800 and cp <= 0xDBFF) {
              // Expect a low surrogate immediately after: \uXXXX
              if (i + 11 < len and chars[i + 6] == '\\' and chars[i + 7] == 'u') {
                switch (parseHex4(chars, i + 8)) {
                  case (?lo) {
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                      // Valid pair — combine into real codepoint
                      let codepoint : Nat32 = 0x10000 + ((cp - 0xD800) * 0x400) + (lo - 0xDC00);
                      out #= Text.fromChar(Char.fromNat32(codepoint));
                      i += 12; // skip both \uXXXX sequences
                    } else {
                      // Low after high is not a low surrogate — emit replacement
                      out #= Text.fromChar(Char.fromNat32(0xFFFD));
                      i += 6;
                    };
                  };
                  case null {
                    // Invalid hex in second escape — emit replacement
                    out #= Text.fromChar(Char.fromNat32(0xFFFD));
                    i += 6;
                  };
                };
              } else {
                // High surrogate without a following \uXXXX — emit replacement
                out #= Text.fromChar(Char.fromNat32(0xFFFD));
                i += 6;
              };
            } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
              // Lone low surrogate — emit replacement
              out #= Text.fromChar(Char.fromNat32(0xFFFD));
              i += 6;
            } else {
              // Normal \uXXXX escape — pass through unchanged
              out #= Text.fromChar(chars[i]);
              i += 1;
            };
          };
          case null {
            // Not a valid \uXXXX — just emit the backslash
            out #= Text.fromChar(chars[i]);
            i += 1;
          };
        };
      } else {
        out #= Text.fromChar(chars[i]);
        i += 1;
      };
    };

    out;
  };

};
