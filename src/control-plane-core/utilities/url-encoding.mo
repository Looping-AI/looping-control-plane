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

};
