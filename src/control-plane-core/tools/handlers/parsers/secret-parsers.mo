import Types "../../../types";

module {
  public func parseSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("groqApiKey") { ?#groqApiKey };
      case ("openaiApiKey") { ?#openaiApiKey };
      case ("slackBotToken") { ?#slackBotToken };
      case ("slackSigningSecret") { ?#slackSigningSecret };
      case _ { null };
    };
  };
};
