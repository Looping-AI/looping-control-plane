import Json "mo:json";
import { str; obj; bool } "mo:json";
import List "mo:core/List";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Error "mo:core/Error";
import Nat "mo:core/Nat";
import AgentModel "../../../models/agent-model";
import ExecutionTypes "../../../types/execution";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import Constants "../../../constants";
import SlackWrapper "../../../wrappers/slack-wrapper";
import InternalEngine "../../../../internal-engine/main";
import EngineDispatchService "../../../services/engine-dispatch-service";

module {

  // ─── Resource types (mirrored from ToolResources for clarity) ───────────────

  public type EngineDispatch = {
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    internalEngine : InternalEngine.InternalEngine;
  };

  public type EnvelopeContext = {
    agent : AgentModel.AgentRecord;
    turnId : Text;
    instructions : Text;
    messages : [ExecutionTypes.ChatMessage];
    apiKey : Text;
  };

  // ─── Tool definition ─────────────────────────────────────────────────────────

  /// Tool definition exposed for the FunctionToolRegistry.
  public let definition = {
    tool_type = "function";
    function = {
      name = "dispatch_workflow";
      description = ?"Dispatches a workflow to the execution engine for administrative operations. Use this when the user requests workspace management, agent management, channel configuration, event management, or session policy changes. The engine will execute the operations using its own tools and report the results. For most operations, pass an empty permits array. Only include permits for sensitive operations: 'deleteWorkspace' (requires workspace ID; ONLY include if the user's message explicitly contains both 'delete' and the workspace name, e.g. 'Delete marketing' - do NOT fabricate this confirmation) or 'setAdminChannel' (requires channel ID).";
      parameters = ?"{\"type\":\"object\",\"properties\":{\"workflowId\":{\"type\":\"string\",\"description\":\"The workflow ID to execute. Use 'admin-v1' for administrative operations.\"},\"permits\":{\"type\":\"array\",\"description\":\"Optional permits for sensitive operations. Empty array for standard operations.\",\"items\":{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"deleteWorkspace\",\"setAdminChannel\"],\"description\":\"The permit type.\"},\"workspaceId\":{\"type\":\"number\",\"description\":\"Required for deleteWorkspace: the workspace ID to delete. Only include this permit when the user's message explicitly contains both 'delete' and the workspace name (e.g. 'Delete marketing'). Never fabricate this confirmation.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Required for setAdminChannel: the Slack channel ID to set as admin channel.\"}},\"required\":[\"type\"]}}},\"required\":[\"workflowId\"]}";
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
    resolveSlackBotToken : ?(Text -> ?Text),
    triggerMessageText : ?Text,
    resolveWorkspaceName : ?(Nat -> ?Text),
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
          switch (validateDeleteWorkspacePermit(triggerMessageText, workspaceId, resolveWorkspaceName)) {
            case (#ok) {};
            case (#err(msg)) { return dispatchError(msg) };
          };
        };
        case (#setAdminChannel({ channelId })) {
          switch (await validateSetAdminChannelPermit(resolveSlackBotToken, channelId)) {
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
      switch (await EngineDispatchService.dispatch(engineDispatch.envelopeState, engineDispatch.internalEngine, envelope)) {
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
  /// both "delete" and the workspace name (case-insensitive) as explicit confirmation.
  /// This prevents the LLM from fabricating a delete confirmation the user never typed.
  private func validateDeleteWorkspacePermit(
    triggerMessageText : ?Text,
    workspaceId : Nat,
    resolveWorkspaceName : ?(Nat -> ?Text),
  ) : { #ok; #err : Text } {
    let workspaceName = switch (resolveWorkspaceName) {
      case (null) {
        return #err("Cannot validate delete workspace permit: workspace resolver not available");
      };
      case (?resolve) {
        switch (resolve(workspaceId)) {
          case (null) {
            return #err("Cannot validate delete workspace permit: workspace " # Nat.toText(workspaceId) # " not found");
          };
          case (?name) { name };
        };
      };
    };
    switch (triggerMessageText) {
      case (null) {
        #err("Cannot validate delete workspace permit: no trigger message available");
      };
      case (?text) {
        let lower = Text.toLower(text);
        let lowerName = Text.toLower(workspaceName);
        if (Text.contains(lower, #text "delete") and Text.contains(lower, #text lowerName)) {
          #ok;
        } else {
          #err("User's message must contain both 'delete' and the workspace name '" # workspaceName # "' (e.g. 'Delete " # workspaceName # "'). Ask the user to send that exact confirmation.");
        };
      };
    };
  };

  /// Validate #setAdminChannel permit: verify the channel exists and is
  /// accessible via the Slack API.
  private func validateSetAdminChannelPermit(
    resolveSlackBotToken : ?(Text -> ?Text),
    channelId : Text,
  ) : async { #ok; #err : Text } {
    let token = switch (resolveSlackBotToken) {
      case (null) {
        return #err("Cannot validate admin channel permit: no Slack bot token available");
      };
      case (?resolve) {
        switch (resolve("validate-admin-channel")) {
          case (null) {
            return #err("Cannot validate admin channel permit: no Slack bot token available");
          };
          case (?t) { t };
        };
      };
    };
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
