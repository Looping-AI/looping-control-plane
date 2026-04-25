import Json "mo:json";
import { str; obj; int } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import List "mo:core/List";

module {
  /// Build a success response JSON string with an id and action
  public func buildSuccessResponse(id : Nat, action : Text) : Text {
    Json.stringify(
      obj([
        ("success", #bool(true)),
        ("id", int(id)),
        ("action", str(action)),
      ]),
      null,
    );
  };

  /// Build an error response JSON string
  public func buildErrorResponse(message : Text) : Text {
    Json.stringify(
      obj([
        ("success", #bool(false)),
        ("error", str(message)),
      ]),
      null,
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
