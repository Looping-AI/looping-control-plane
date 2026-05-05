/// URL Encoding
/// Provides percent-encoding for URL query parameter values.
///
/// Characters that are "unreserved" in RFC 3986 (A-Z, a-z, 0-9, -, _, ., ~)
/// are left as-is. All other characters — including base64 characters like
/// +, /, and = that appear in Slack pagination cursors — are percent-encoded
/// using their UTF-8 byte representation.
///
/// Slack-specific note: pagination cursor values are base64-encoded and
/// typically end with "=" (which must become "%3D"). The "+" and "/" characters
/// in base64 also require encoding ("%2B" and "%2F" respectively).
/// See: https://api.slack.com/docs/pagination

import Text "mo:core/Text";
import Char "mo:core/Char";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import VarArray "mo:core/VarArray";
import Result "mo:core/Result";

module {

  /// Upper-case hex digits lookup.
  private let hexDigits : [Char] = [
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
  ];

  /// Returns true if a character is "unreserved" per RFC 3986
  /// and therefore safe to include verbatim in a URL query value.
  ///
  /// Unreserved characters: A-Z  a-z  0-9  -  _  .  ~
  private func isUnreserved(c : Char) : Bool {
    let n = Char.toNat32(c);
    // a-z
    (n >= 0x61 and n <= 0x7A)
    // A-Z
    or (n >= 0x41 and n <= 0x5A)
    // 0-9
    or (n >= 0x30 and n <= 0x39)
    // - _ . ~
    or n == 0x2D or n == 0x5F or n == 0x2E or n == 0x7E;
  };

  /// Percent-encode a single byte as "%XX" (upper-case hex).
  private func encodeByte(byte : Nat8) : Text {
    let hi = hexDigits[Nat8.toNat(byte / 16)];
    let lo = hexDigits[Nat8.toNat(byte % 16)];
    "%" # Char.toText(hi) # Char.toText(lo);
  };

  /// Percent-encode a text value for safe use as a URL query parameter value.
  ///
  /// Unreserved characters (A-Z, a-z, 0-9, -, _, ., ~) pass through unchanged.
  /// All other characters are converted to their UTF-8 byte representation and
  /// each byte is percent-encoded as %XX (upper-case hex).
  ///
  /// Examples:
  ///   encodeQueryValue("hello")                  → "hello"
  ///   encodeQueryValue("dXNlcjpVMEc5V0ZYTlo=")  → "dXNlcjpVMEc5V0ZYTlo%3D"
  ///   encodeQueryValue("a+b/c=d")                → "a%2Bb%2Fc%3Dd"
  ///   encodeQueryValue("café")                   → "caf%C3%A9"
  public func encodeQueryValue(value : Text) : Text {
    Text.flatMap(
      value,
      func(c : Char) : Text {
        if (isUnreserved(c)) {
          Char.toText(c);
        } else {
          // Convert character to UTF-8 bytes via Text.encodeUtf8, then
          // percent-encode each byte.
          let blob = Text.encodeUtf8(Char.toText(c));
          var encoded = "";
          for (byte in blob.vals()) {
            encoded #= encodeByte(byte);
          };
          encoded;
        };
      },
    );
  };

  // ─── Decoding ─────────────────────────────────────────────────────────────

  /// Interpret a single hex character ('0'-'9', 'A'-'F', 'a'-'f') as its
  /// numeric value, or null for non-hex characters.
  private func hexCharToNat(c : Char) : ?Nat8 {
    let n = Char.toNat32(c);
    if (n >= 0x30 and n <= 0x39) {
      return ?(Nat8.fromNat(Nat32.toNat(n - 0x30)));
    }; // '0'-'9'
    if (n >= 0x41 and n <= 0x46) {
      return ?(Nat8.fromNat(Nat32.toNat(n - 0x41 + 10)));
    }; // 'A'-'F'
    if (n >= 0x61 and n <= 0x66) {
      return ?(Nat8.fromNat(Nat32.toNat(n - 0x61 + 10)));
    }; // 'a'-'f'
    null;
  };

  /// Percent-decode a URL query parameter value (application/x-www-form-urlencoded).
  ///
  /// - `%XX` sequences are decoded to their byte values.
  /// - `+` is decoded as a space (HTML form encoding).
  /// - Other characters pass through unchanged.
  ///
  /// Returns `#ok(decoded)` on success. Returns `#err` if any `%XX` byte sequence
  /// decodes to invalid UTF-8 (e.g. a lone continuation byte `%80`, or a truncated
  /// multi-byte sequence such as `%C3` at end of input).
  ///
  /// `%XX` sequences with non-hex digits (e.g. `%GG`) pass through verbatim and do
  /// not cause an `#err`.
  public func decodeQueryValue(value : Text) : Result.Result<Text, Text> {
    let chars = Text.toIter(value);
    var result = "";

    // Growing buffer for accumulating UTF-8 bytes from consecutive %XX sequences.
    // Flushed to text whenever a non-%XX character is encountered or at end.
    var buf : [var Nat8] = VarArray.repeat<Nat8>(0, 16);
    var bufLen = 0;
    var failed = false;

    // Flush all accumulated bytes in buf as decoded UTF-8 text.
    // On invalid UTF-8, sets failed = true and discards the bytes.
    let flushBytes = func() {
      if (bufLen > 0) {
        let slice = Array.tabulate<Nat8>(bufLen, func(i) { buf[i] });
        switch (Text.decodeUtf8(Blob.fromArray(slice))) {
          case (?t) { result #= t };
          case null {
            // Invalid UTF-8 — signal failure and discard the bytes.
            failed := true;
          };
        };
        bufLen := 0;
      };
    };

    label L loop {
      let c = switch (chars.next()) { case null break L; case (?c) c };

      if (c == '%') {
        // Try to read two hex digits
        let h1 = switch (chars.next()) {
          case null { flushBytes(); result #= "%"; break L };
          case (?h) h;
        };
        let h2 = switch (chars.next()) {
          case null { flushBytes(); result #= "%" # Char.toText(h1); break L };
          case (?h) h;
        };
        switch (hexCharToNat(h1), hexCharToNat(h2)) {
          case (?hi, ?lo) {
            // Valid %XX — accumulate byte for multi-byte UTF-8 decoding
            if (bufLen >= buf.size()) {
              // Grow the buffer by doubling
              let newBuf = VarArray.repeat<Nat8>(0, buf.size() * 2);
              var i = 0;
              while (i < bufLen) { newBuf[i] := buf[i]; i += 1 };
              buf := newBuf;
            };
            buf[bufLen] := hi * 16 + lo;
            bufLen += 1;
          };
          case _ {
            // Not valid hex — flush buffered bytes, pass through verbatim
            flushBytes();
            result #= "%" # Char.toText(h1) # Char.toText(h2);
          };
        };
      } else {
        // Non-% character — flush any buffered bytes first
        flushBytes();
        if (c == '+') {
          result #= " "; // form-encoding: + represents space
        } else {
          result #= Char.toText(c);
        };
      };
    };
    flushBytes();
    if (failed) #err("invalid UTF-8 byte sequence in percent-encoded input") else #ok(result);
  };

};
