import Json "mo:json";
import { str; obj; bool } "mo:json";
import List "mo:core/List";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Error "mo:core/Error";
import AgentModel "../../models/agent-model";
import ExecutionTypes "../../types/execution";
import ExecutionEnvelopeModel "../../models/execution-envelope-model";
import Constants "../../constants";
import SlackWrapper "../../wrappers/slack-wrapper";

module {

  // ─── Resource types (mirrored from ToolResources for clarity) ───────────────

  public type EngineDispatch = {
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    dispatchToEngine : (ExecutionTypes.EnvelopePayload) -> async {
      #ok;
      #err : Text;
    };
  };

  public type EnvelopeContext = {
    agent : AgentModel.AgentRecord;
    turnId : Text;
    instructions : Text;
    messages : [ExecutionTypes.ChatMessage];
    botToken : ?Text;
    apiKey : Text;
  };

  // ─── Tool definition ─────────────────────────────────────────────────────────

  /// Tool definition exposed for the FunctionToolRegistry.
  public let definition = {
    tool_type = "function";
    function = {
      name = "dispatch_workflow";
      description = ?"Dispatches a workflow to the execution engine for administrative operations. Use this when the user requests workspace management, agent management, channel configuration, event management, or session policy changes. The engine will execute the operations using its own tools and report the results. For most operations, pass an empty permits array. Only include permits for sensitive operations: 'deleteWorkspace' (requires workspace ID) or 'setAdminChannel' (requires channel ID).";
      parameters = ?"{\"type\":\"object\",\"properties\":{\"workflowId\":{\"type\":\"string\",\"description\":\"The workflow ID to execute. Use 'admin-v1' for administrative operations.\"},\"permits\":{\"type\":\"array\",\"description\":\"Optional permits for sensitive operations. Empty array for standard operations.\",\"items\":{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"deleteWorkspace\",\"setAdminChannel\"],\"description\":\"The permit type.\"},\"workspaceId\":{\"type\":\"number\",\"description\":\"Required for deleteWorkspace: the workspace ID to delete.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Required for setAdminChannel: the Slack channel ID to set as admin channel.\"}},\"required\":[\"type\"]}}},\"required\":[\"workflowId\"]}";
    };
  };

  // ─── Handler ─────────────────────────────────────────────────────────────────

  /// Validates permits, builds an EnvelopePayload, and dispatches to the engine.
  ///
  /// Returns JSON with `{ "dispatched": true }` on success so the orchestrator
  /// can detect the signal uniformly (like any other tool result).
  /// Returns `{ "dispatched": false, "error": "..." }` on validation or dispatch failure
  /// so the LLM can reason about the error and retry or inform the user.
  public func handle(
    engineDispatch : EngineDispatch,
    envelopeContext : EnvelopeContext,
    triggerMessageText : ?Text,
    args : Text,
  ) : async Text {
    // Parse arguments
    let parsed = switch (Json.parse(args)) {
      case (#err(_)) {
        return dispatchError("Invalid JSON arguments for dispatch_workflow");
      };
      case (#ok(json)) { json };
    };

    let workflowId = switch (Json.get(parsed, "workflowId")) {
      case (?#string(id)) { id };
      case (_) {
        return dispatchError("Missing or invalid 'workflowId' in dispatch_workflow arguments");
      };
    };

    // Parse optional permits array
    let permits = parsePermits(parsed);

    // Validate each permit
    for (permit in permits.vals()) {
      switch (permit) {
        case (#deleteWorkspace({ workspaceId })) {
          switch (validateDeleteWorkspacePermit(triggerMessageText, workspaceId)) {
            case (#ok) {};
            case (#err(msg)) { return dispatchError(msg) };
          };
        };
        case (#setAdminChannel({ channelId })) {
          switch (await validateSetAdminChannelPermit(envelopeContext.botToken, channelId)) {
            case (#ok) {};
            case (#err(msg)) { return dispatchError(msg) };
          };
        };
      };
    };

    // All permits validated — build envelope and dispatch
    let scopeGrants = buildScopeGrants(envelopeContext.agent);

    let { envelopeId; nonce = envelopeNonce } = ExecutionEnvelopeModel.issue(
      engineDispatch.envelopeState,
      envelopeContext.turnId,
      envelopeContext.agent.ownedBy,
      scopeGrants,
      permits,
    );

    let envelope : ExecutionTypes.EnvelopePayload = {
      envelopeId;
      dispatchedVersion = null; // means not dispatched yet.
      requestId = envelopeContext.turnId;
      agentId = envelopeContext.agent.id;
      agentName = envelopeContext.agent.config.name;
      workspaceId = envelopeContext.agent.ownedBy;
      workflowId;
      messages = envelopeContext.messages;
      instructions = envelopeContext.instructions;
      constraints = {
        maxRounds = Constants.MAX_AGENT_ROUNDS;
        maxTokenBudget = null;
      };
      secrets = {
        apiKeys = [("openrouter", envelopeContext.apiKey), ("model", envelopeContext.agent.config.model)];
      };
      scopeGrants;
      permits;
      envelopeNonce;
    };

    try {
      switch (await engineDispatch.dispatchToEngine(envelope)) {
        case (#ok) {
          Json.stringify(obj([("dispatched", bool(true))]), null);
        };
        case (#err(e)) {
          ExecutionEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
          dispatchError("Engine dispatch failed: " # e);
        };
      };
    } catch (e : Error) {
      ExecutionEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
      dispatchError("Engine call failed: " # Error.message(e));
    };
  };

  // ─── Permit validation ───────────────────────────────────────────────────────

  /// Validate #deleteWorkspace permit: the user's trigger message must contain
  /// "delete" as confirmation. This prevents the LLM from fabricating a delete
  /// confirmation that the user never typed.
  private func validateDeleteWorkspacePermit(
    triggerMessageText : ?Text,
    _workspaceId : Nat,
  ) : { #ok; #err : Text } {
    switch (triggerMessageText) {
      case (null) {
        #err("Cannot validate delete workspace permit: no trigger message available");
      };
      case (?text) {
        let lower = Text.toLower(text);
        if (Text.contains(lower, #text "delete")) {
          #ok;
        } else {
          #err("User's message does not contain 'delete' confirmation. Ask the user to explicitly confirm deletion in their message.");
        };
      };
    };
  };

  /// Validate #setAdminChannel permit: verify the channel exists and is
  /// accessible via the Slack API.
  private func validateSetAdminChannelPermit(
    botToken : ?Text,
    channelId : Text,
  ) : async { #ok; #err : Text } {
    switch (botToken) {
      case (null) {
        #err("Cannot validate admin channel permit: no Slack bot token available");
      };
      case (?token) {
        try {
          switch (await SlackWrapper.getChannelInfo(token, channelId)) {
            case (#ok(_)) { #ok };
            case (#err(e)) {
              #err("Channel verification failed for " # channelId # ": " # e);
            };
          };
        } catch (e : Error) {
          #err("Slack API call failed: " # Error.message(e));
        };
      };
    };
  };

  // ─── Scope and permit helpers ────────────────────────────────────────────────

  /// Build scope grants based on agent category and ownership.
  private func buildScopeGrants(agent : AgentModel.AgentRecord) : [ExecutionTypes.ScopeGrant] {
    switch (agent.category) {
      case (#_system(#admin)) {
        if (AgentModel.isOrgAdmin(agent)) {
          [
            #workspace({ access = #write }),
            #agents({ access = #write }),
            #slackQueue({ access = #write }),
            #session({ access = #write }),
          ];
        } else {
          [
            #workspace({ access = #read }),
            #agents({ access = #write }),
            #session({ access = #write }),
          ];
        };
      };
      case (#_system(#onboarding) or #custom) {
        [#agent({ id = agent.id; access = #read })];
      };
    };
  };

  /// Parse a JSON permits array into [OperationPermit].
  private func parsePermits(json : Json.Json) : [ExecutionTypes.OperationPermit] {
    let permitsJson = switch (Json.get(json, "permits")) {
      case (?#array(arr)) { arr };
      case (_) { return [] };
    };
    let result = List.empty<ExecutionTypes.OperationPermit>();
    for (p in permitsJson.vals()) {
      let permitType = switch (Json.get(p, "type")) {
        case (?#string(t)) { t };
        case (_) { "" };
      };
      if (permitType == "deleteWorkspace") {
        switch (Json.get(p, "workspaceId")) {
          case (?#number(#int(n))) {
            List.add(result, #deleteWorkspace({ workspaceId = Int.abs(n) }));
          };
          case (?#number(#float(f))) {
            List.add(result, #deleteWorkspace({ workspaceId = Int.abs(Float.toInt(f)) }));
          };
          case (_) {};
        };
      } else if (permitType == "setAdminChannel") {
        switch (Json.get(p, "channelId")) {
          case (?#string(c)) {
            List.add(result, #setAdminChannel({ channelId = c }));
          };
          case (_) {};
        };
      };
    };
    List.toArray(result);
  };

  // ─── Response helpers ────────────────────────────────────────────────────────

  private func dispatchError(message : Text) : Text {
    Json.stringify(
      obj([
        ("dispatched", bool(false)),
        ("error", str(message)),
      ]),
      null,
    );
  };
};
