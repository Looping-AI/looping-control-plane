import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import AgentModel "../../../models/agent-model";
import Types "../../../types";

module {
  private func categoryToText(c : AgentModel.AgentCategory) : Text {
    switch (c) {
      case (#admin) { "admin" };
      case (#planning) { "planning" };
      case (#research) { "research" };
      case (#communication) { "communication" };
    };
  };

  private func llmModelToText(m : AgentModel.LlmModel) : Text {
    switch (m) {
      case (#openRouter(#gpt_oss_120b)) { "gpt_oss_120b" };
    };
  };

  private func secretIdToText(s : Types.SecretId) : Text {
    switch (s) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#openaiApiKey) { "openaiApiKey" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
    };
  };

  private func agentToJson(record : AgentModel.AgentRecord) : Json.Json {
    let secretsJson = arr(
      Array.map<(Nat, Types.SecretId), Json.Json>(
        record.secretsAllowed,
        func((wsId, sid)) {
          obj([
            ("workspaceId", int(wsId)),
            ("secretId", str(secretIdToText(sid))),
          ]);
        },
      )
    );
    let disallowedJson = arr(Array.map<Text, Json.Json>(record.toolsDisallowed, str));
    let misconfiguredJson = arr(Array.map<Text, Json.Json>(record.toolsMisconfigured, str));
    let sourcesJson = arr(Array.map<Text, Json.Json>(record.sources, str));
    obj([
      ("id", int(record.id)),
      ("name", str(record.name)),
      ("category", str(categoryToText(record.category))),
      ("llmModel", str(llmModelToText(record.llmModel))),
      ("secretsAllowed", secretsJson),
      ("toolsDisallowed", disallowedJson),
      ("toolsMisconfigured", misconfiguredJson),
      ("sources", sourcesJson),
    ]);
  };

  public func handle(
    state : AgentModel.AgentRegistryState,
    _args : Text,
  ) : async Text {
    let records = AgentModel.listAgents(state);
    let items = Array.map<AgentModel.AgentRecord, Json.Json>(records, agentToJson);
    Json.stringify(
      obj([
        ("success", bool(true)),
        ("agents", arr(items)),
      ]),
      null,
    );
  };
};
