import Types "../../../types";
import Text "mo:core/Text";
import Iter "mo:core/Iter";

module {
  public func parseSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("openRouterApiKey") { ?#openRouterApiKey };
      case ("openaiApiKey") { ?#openaiApiKey };
      case ("anthropicApiKey") { ?#anthropicApiKey };
      case ("anthropicSetupToken") { ?#anthropicSetupToken };
      case ("slackBotToken") { ?#slackBotToken };
      case ("slackSigningSecret") { ?#slackSigningSecret };
      case _ {
        // Accept "custom:<name>" as #custom(name)
        if (Text.startsWith(s, #text "custom:")) {
          let name = Text.fromIter(Iter.drop(Text.toIter(s), 7));
          if (name == "") { null } else { ?#custom(name) };
        } else { null };
      };
    };
  };
};
