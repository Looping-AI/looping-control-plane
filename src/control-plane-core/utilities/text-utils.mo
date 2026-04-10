/// Text Utilities
///
/// General-purpose text helper functions used across the codebase.

import Nat "mo:core/Nat";
import Text "mo:core/Text";

module {

  /// Truncate `text` to approximately `maxChars` characters using a bilateral
  /// split: keep the first half and the last half, with a `[TRUNCATED]` marker
  /// in the middle. Returns the text unchanged if it is at or below the limit.
  ///
  /// The output length is approximately `maxChars + Text.size("[TRUNCATED]")`.
  /// The split is biased toward the start: `firstHalf = maxChars / 2`,
  /// `lastHalf = maxChars - firstHalf`.
  ///
  /// Edge cases:
  ///   - `maxChars = 0` → returns `"[TRUNCATED]"`
  ///   - `maxChars = 1` → `[TRUNCATED]` + last 1 char (first half rounds down to zero)
  public func truncateMiddle(text : Text, maxChars : Nat) : Text {
    let size = Text.size(text);
    if (size <= maxChars) { return text };

    let firstHalf = maxChars / 2;
    let lastHalf = Nat.sub(maxChars, firstHalf);

    // Collect characters into an array for random access
    let chars = Text.toArray(text);

    // Build prefix (first `firstHalf` chars)
    var prefix = "";
    var i = 0;
    while (i < firstHalf) {
      prefix #= Text.fromChar(chars[i]);
      i += 1;
    };

    // Build suffix (last `lastHalf` chars)
    var suffix = "";
    var j = Nat.sub(size, lastHalf);
    while (j < size) {
      suffix #= Text.fromChar(chars[j]);
      j += 1;
    };

    prefix # "[TRUNCATED]" # suffix;
  };

};
