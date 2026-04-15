import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import Set "mo:core/Set";
import AgentModel "../../../models/agent-model";
import Types "../../../types";

module {
  private func categoryToText(c : AgentModel.AgentCategory) : Text {
    switch (c) {
      case (#_system(#admin)) { "system:admin" };
      case (#_system(#onboarding)) { "system:onboarding" };
      case (#custom) { "custom" };
    };
  };

  private func executionEngineToText(e : AgentModel.ExecutionEngine) : Text {
    switch (e) {
      case (#api) { "api" };
      case (#canister) { "canister" };
      case (#github) { "github" };
    };
  };

  private func secretIdToText(s : Types.SecretId) : Text {
    switch (s) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#anthropicApiKey) { "anthropicApiKey" };
      case (#anthropicSetupToken) { "anthropicSetupToken" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
      case (#custom(name)) { "custom:" # name };
    };
  };

  private func agentToJson(record : AgentModel.AgentRecord) : Json.Json {
    let secretsAllowedJson = arr(
      Array.map<(Nat, Types.SecretId), Json.Json>(
        record.config.secrets.allowed,
        func((wsId, sid)) {
          obj([
            ("workspaceId", int(wsId)),
            ("secretId", str(secretIdToText(sid))),
          ]);
        },
      )
    );
    let overridesJson = arr(
      Array.map<(Types.SecretId, Text), Json.Json>(
        record.config.secrets.overrides,
        func((sid, customName)) {
          obj([
            ("secretId", str(secretIdToText(sid))),
            ("customKeyName", str(customName)),
          ]);
        },
      )
    );
    let allowedChannelIdsJson = arr(
      Array.map<Text, Json.Json>(Set.toArray(record.config.allowedChannelIds), str)
    );
    obj([
      ("id", int(record.id)),
      ("ownedBy", int(record.ownedBy)),
      ("category", str(categoryToText(record.category))),
      (
        "config",
        obj([
          ("name", str(record.config.name)),
          ("model", str(record.config.model)),
          ("executionEngines", arr(Array.map<AgentModel.ExecutionEngine, Json.Json>(record.config.executionEngines, func(e) { str(executionEngineToText(e)) }))),
          ("allowedChannelIds", allowedChannelIdsJson),
          (
            "secrets",
            obj([
              ("allowed", secretsAllowedJson),
              ("overrides", overridesJson),
            ]),
          ),
        ]),
      ),
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
