import Json "mo:json";
import { str; obj } "mo:json";
import Int "mo:core/Int";
import List "mo:core/List";
import ToolTypes "../tool-types";

module {
  /// Build a structured ToolCallOutcome error: {"type":"camelCase","message":"..."}
  public func makeError(errType : Text, message : Text) : ToolTypes.ToolCallOutcome {
    #err(
      Json.stringify(
        obj([
          ("type", str(errType)),
          ("message", str(message)),
        ]),
        null,
      )
    );
  };

  /// Extract a [Nat] from a JSON array, skipping non-nat values
  public func extractNatArray(jsonArray : [Json.Json]) : [Nat] {
    let buffer = List.empty<Nat>();
    for (item in jsonArray.vals()) {
      switch (item) {
        case (#number(#int n)) {
          if (n >= 0) {
            List.add(buffer, Int.abs(n));
          };
        };
        case _ {};
      };
    };
    List.toArray(buffer);
  };

  /// Parse a JSON array of strings. Returns null if any element is not a string.
  public func parseStringArray(jsonArray : [Json.Json]) : ?[Text] {
    let buffer = List.empty<Text>();
    for (item in jsonArray.vals()) {
      switch (item) {
        case (#string(s)) { List.add(buffer, s) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };
};
