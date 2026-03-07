import Debug "mo:core/Debug";
import Text "mo:core/Text";
import Constants "../constants";

module {
  /// Log level for filtering and categorizing messages
  public type LogLevel = {
    #_debug; // "_" prefix needed, `debug` is reserved in Motoko
    #info;
    #warn;
    #error;
  };

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

  /// Check if logging should occur based on environment and level
  /// - test: no logs
  /// - local: all levels
  /// - staging: warn and error only
  /// - production: error only
  private func shouldLog(level : LogLevel) : Bool {
    switch (Constants.ENVIRONMENT) {
      case (#test) { false };
      case (#local) { true };
      case (#staging) { true };
      case (#production) {
        switch (level) {
          case (#error) { true };
          case _ { false };
        };
      };
    };
  };

  /// Log a message at the specified level
  /// Respects environment-specific log level filtering
  public func log(level : LogLevel, domain : ?Text, message : Text) {
    if (shouldLog(level)) {
      Debug.print(formatMessage(level, domain, message));
    };
  };
};
