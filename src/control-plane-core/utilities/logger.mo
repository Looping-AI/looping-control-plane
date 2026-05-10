import Debug "mo:core/Debug";
import Text "mo:core/Text";
import Types "../types";
import Constants "../constants";

module {
  public type LogLevel = Types.LogLevel;

  /// Convert log level to text representation
  private func levelToText(level : LogLevel) : Text {
    switch (level) {
      case (#_debug) { "DEBUG" };
      case (#info) { "INFO" };
      case (#warn) { "WARN" };
      case (#error) { "ERROR" };
    };
  };

  /// Format log message with level and optional domain
  private func formatMessage(level : LogLevel, domain : ?Text, message : Text) : Text {
    let levelText = levelToText(level);
    switch (domain) {
      case (null) { "[" # levelText # "] " # message };
      case (?d) { "[" # levelText # "][" # d # "] " # message };
    };
  };

  /// Numeric value for a log level (used for threshold comparison)
  private func levelValue(level : LogLevel) : Nat {
    switch (level) {
      case (#_debug) { 0 };
      case (#info) { 1 };
      case (#warn) { 2 };
      case (#error) { 3 };
    };
  };

  /// Check if logging should occur based on configured minimum level
  private func shouldLog(level : LogLevel) : Bool {
    levelValue(level) >= levelValue(Constants.MIN_LOG_LEVEL);
  };

  /// Log a message at the specified level
  /// Respects the configured minimum log level threshold
  public func log(level : LogLevel, domain : ?Text, message : Text) {
    if (shouldLog(level)) {
      Debug.print(formatMessage(level, domain, message));
    };
  };
};
