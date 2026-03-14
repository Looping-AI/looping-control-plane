import Json "mo:json";
import List "mo:core/List";
import Int "mo:core/Int";
import AgentModel "../../../models/agent-model";
import Types "../../../types";

module {
  public func parseCategory(s : Text) : ?AgentModel.AgentCategory {
    switch (s) {
      case ("admin") { ?#admin };
      case ("planning") { ?#planning };
      case ("research") { ?#research };
      case ("communication") { ?#communication };
      case _ { null };
    };
  };

  public func parseLlmModel(s : Text) : ?AgentModel.LlmModel {
    switch (s) {
      case ("gpt_oss_120b") { ?#groq(#gpt_oss_120b) };
      case ("groq:gpt_oss_120b") { ?#groq(#gpt_oss_120b) };
      case _ { null };
    };
  };

  /// Parse a SecretId for agent use. Excludes `#slackSigningSecret` which is
  /// a system-level secret not grantable to agents.
  public func parseAgentSecretId(s : Text) : ?Types.SecretId {
    switch (s) {
      case ("groqApiKey") { ?#groqApiKey };
      case ("openaiApiKey") { ?#openaiApiKey };
      case ("slackBotToken") { ?#slackBotToken };
      case _ { null };
    };
  };

  public func parseSecretsAllowed(items : [Json.Json]) : ?[(Nat, Types.SecretId)] {
    let buffer = List.empty<(Nat, Types.SecretId)>();
    for (item in items.vals()) {
      let wsIdOpt = switch (Json.get(item, "workspaceId")) {
        case (?#number(#int n)) { if (n >= 0) ?Int.abs(n) else null };
        case _ { null };
      };
      let sidOpt = switch (Json.get(item, "secretId")) {
        case (?#string(s)) { parseAgentSecretId(s) };
        case _ { null };
      };
      switch (wsIdOpt, sidOpt) {
        case (?wsId, ?sid) { List.add(buffer, (wsId, sid)) };
        case _ { return null };
      };
    };
    ?List.toArray(buffer);
  };

  public func parseExecutionType(json : Json.Json) : ?AgentModel.AgentExecutionType {
    let typeStr = switch (Json.get(json, "type")) {
      case (?#string(s)) { s };
      case _ { return null };
    };
    switch (typeStr) {
      case ("api") { ?#api };
      case ("runtime") {
        let hostingStr = switch (Json.get(json, "hosting")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        let frameworkStr = switch (Json.get(json, "framework")) {
          case (?#string(s)) { s };
          case _ { return null };
        };
        switch (hostingStr, frameworkStr) {
          case ("codespace", "openClaw") {
            ?#runtime {
              hosting = #codespace;
              framework = #openClaw { deployedVersion = null };
            };
          };
          case _ { null };
        };
      };
      case _ { null };
    };
  };
};
