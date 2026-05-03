import Text "mo:core/Text";
import Array "mo:core/Array";
import Int "mo:core/Int";
import Json "mo:json";

module {

  /// Pretty-print a JSON value with 2-space indentation.
  /// Produces human-readable output suitable for a Slack code block.
  public func prettyPrint(json : Json.Json, depth : Nat) : Text {
    let indent = Text.join(Array.tabulate<Text>(depth * 2, func(_ : Nat) : Text { " " }).vals(), "");
    let innerIndent = Text.join(Array.tabulate<Text>((depth + 1) * 2, func(_ : Nat) : Text { " " }).vals(), "");
    switch (json) {
      case (#null_) { "null" };
      case (#bool(b)) { if (b) "true" else "false" };
      case (#number(#int(n))) { Int.toText(n) };
      case (#number(#float(f))) { debug_show (f) };
      case (#string(s)) { "\"" # escapeJsonString(s) # "\"" };
      case (#array(items)) {
        if (items.size() == 0) { "[]" } else {
          var result = "[\n";
          var i = 0;
          for (item in items.vals()) {
            result #= innerIndent # prettyPrint(item, depth + 1);
            if (i + 1 < items.size()) { result #= "," };
            result #= "\n";
            i += 1;
          };
          result #= indent # "]";
          result;
        };
      };
      case (#object_(fields)) {
        if (fields.size() == 0) { "{}" } else {
          var result = "{\n";
          var i = 0;
          for ((key, value) in fields.vals()) {
            result #= innerIndent # "\"" # escapeJsonString(key) # "\": " # prettyPrint(value, depth + 1);
            if (i + 1 < fields.size()) { result #= "," };
            result #= "\n";
            i += 1;
          };
          result #= indent # "}";
          result;
        };
      };
    };
  };

  private func escapeJsonString(s : Text) : Text {
    var result = "";
    for (c in s.chars()) {
      if (c == '\"') { result #= "\\\"" } else if (c == '\\') {
        result #= "\\\\";
      } else if (c == '\n') { result #= "\\n" } else if (c == '\r') {
        result #= "\\r";
      } else if (c == '\t') { result #= "\\t" } else {
        result #= Text.fromChar(c);
      };
    };
    result;
  };

};
