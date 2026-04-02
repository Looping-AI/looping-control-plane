import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import Int "mo:core/Int";
import AgentModel "../../../models/agent-model";
import Helpers "../handler-helpers";
import Types "../../../types";
import AgentParsers "../parsers/agent-parsers";

module {
  private func categoryToText(c : AgentModel.AgentCategory) : Text {
    switch (c) {
      case (#admin) { "admin" };
      case (#planning) { "planning" };
      case (#research) { "research" };
      case (#communication) { "communication" };
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
    let overridesJson = arr(
      Array.map<(Types.SecretId, Text), Json.Json>(
        record.secretOverrides,
        func((sid, customName)) {
          obj([
            ("secretId", str(secretIdToText(sid))),
            ("customKeyName", str(customName)),
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
      ("executionType", AgentParsers.executionTypeToJson(record.executionType)),
      ("secretsAllowed", secretsJson),
      ("secretOverrides", overridesJson),
      ("toolsDisallowed", disallowedJson),
      ("toolsMisconfigured", misconfiguredJson),
      ("sources", sourcesJson),
    ]);
  };

  public func handle(
    state : AgentModel.AgentRegistryState,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(e)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show e);
      };
      case (#ok(json)) {
        // Look up by id (number) or name (string)
        let recordOpt : ?AgentModel.AgentRecord = switch (Json.get(json, "id")) {
          case (?#number(#int n)) {
            if (n >= 0) {
              AgentModel.lookupById(Int.abs(n), state);
            } else {
              null;
            };
          };
          case _ {
            switch (Json.get(json, "name")) {
              case (?#string(name)) { AgentModel.lookupByName(name, state) };
              case _ { null };
            };
          };
        };

        switch (recordOpt) {
          case (null) {
            Helpers.buildErrorResponse("Agent not found. Provide id (number) or name (string).");
          };
          case (?record) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("agent", agentToJson(record)),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
