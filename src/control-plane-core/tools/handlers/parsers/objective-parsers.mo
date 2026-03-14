import Json "mo:json";
import Float "mo:core/Float";
import ObjectiveModel "../../../models/objective-model";

module {
  public func parseObjectiveType(s : Text) : ?ObjectiveModel.ObjectiveType {
    switch (s) {
      case ("target") { ?#target };
      case ("contributing") { ?#contributing };
      case ("prerequisite") { ?#prerequisite };
      case ("guardrail") { ?#guardrail };
      case _ { null };
    };
  };

  /// Parse an ObjectiveTarget from a full JSON object and the already-extracted
  /// targetType string. Returns null for an unrecognised targetType or invalid
  /// field values.
  public func parseObjectiveTarget(json : Json.Json, targetType : Text) : ?ObjectiveModel.ObjectiveTarget {
    switch (targetType) {
      case ("percentage") {
        switch (Json.get(json, "targetValue")) {
          case (?#number(#float f)) { ?#percentage({ target = f }) };
          case (?#number(#int i)) {
            ?#percentage({ target = Float.fromInt(i) });
          };
          case _ { null };
        };
      };
      case ("count") {
        let targetValueOpt = switch (Json.get(json, "targetValue")) {
          case (?#number(#float f)) { ?f };
          case (?#number(#int i)) { ?Float.fromInt(i) };
          case _ { null };
        };
        let directionOpt = switch (Json.get(json, "targetDirection")) {
          case (?#string("increase")) { ?#increase };
          case (?#string("decrease")) { ?#decrease };
          case _ { null };
        };
        switch (targetValueOpt, directionOpt) {
          case (?target, ?direction) { ?#count({ target; direction }) };
          case _ { null };
        };
      };
      case ("threshold") {
        let minOpt = switch (Json.get(json, "targetValue")) {
          case (?#number(#float f)) { ?f };
          case (?#number(#int i)) { ?Float.fromInt(i) };
          case _ { null };
        };
        let maxOpt = switch (Json.get(json, "targetMax")) {
          case (?#number(#float f)) { ?f };
          case (?#number(#int i)) { ?Float.fromInt(i) };
          case _ { null };
        };
        ?#threshold({ min = minOpt; max = maxOpt });
      };
      case ("boolean") {
        switch (Json.get(json, "targetBoolean")) {
          case (?#bool(b)) { ?#boolean(b) };
          case _ { null };
        };
      };
      case _ { null };
    };
  };
};
