import ValueStreamModel "../../../models/value-stream-model";

module {
  public func statusToText(status : ValueStreamModel.ValueStreamStatus) : Text {
    switch (status) {
      case (#draft) { "draft" };
      case (#active) { "active" };
      case (#paused) { "paused" };
      case (#archived) { "archived" };
    };
  };
};
