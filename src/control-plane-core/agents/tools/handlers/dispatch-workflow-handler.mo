import Json "mo:json";
import { str; obj; bool } "mo:json";
import Text "mo:core/Text";
import Error "mo:core/Error";
import AgentModel "../../../models/agent-model";
import ExecutionTypes "../../../types/execution";
import ExecutionEnvelopeModel "../../../models/execution-envelope-model";
import WorkflowCatalogModel "../../../models/workflow-catalog-model";
import WorkflowCatalogService "../../../services/workflow-catalog-service";
import Constants "../../../constants";
import SlackWrapper "../../../wrappers/slack-wrapper";
import InternalEngine "../../../../internal-engine/main";
import EngineDispatchService "../../../services/engine-dispatch-service";
import ToolTypes "../tool-types";

module {

  // ─── Resource types (mirrored from ToolResources for clarity) ───────────────

  public type EngineDispatch = {
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    internalEngine : InternalEngine.InternalEngine;
    catalogState : WorkflowCatalogModel.CatalogState;
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
      description = ?"Dispatches a workflow to the execution engine for administrative operations. Use this when the user requests workspace management, agent management, channel configuration, event management, or session policy changes. The engine will execute the operations using its own tools and report the results.";
      parameters = ?"{\"type\":\"object\",\"properties\":{\"workflowId\":{\"type\":\"string\",\"description\":\"The workflow ID to execute. Use 'admin-v1' for administrative operations.\"}},\"required\":[\"workflowId\"]}";
    };
  };

  // ─── Handler ─────────────────────────────────────────────────────────────────

  /// Builds an EnvelopePayload and dispatches to the engine.
  ///
  /// Returns `#success({ "dispatched": true })` on success so the orchestrator
  /// can detect the signal uniformly (like any other tool result).
  /// Returns `#error({ "dispatched": false, "error": "..." })` on failure
  /// so the LLM can reason about the error and retry or inform the user.
  public func handle(
    engineDispatch : EngineDispatch,
    envelopeContext : EnvelopeContext,
    _resolveSlackBotToken : ?(Text -> ?Text),
    args : Text,
  ) : async ToolTypes.ToolCallOutcome {
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

    // Get the catalog hash before building the envelope.
    // If the cache is empty (first dispatch ever), attempt one refresh.
    let catalogHash = switch (WorkflowCatalogModel.getHash(engineDispatch.catalogState)) {
      case (?h) { h };
      case (null) {
        switch (await WorkflowCatalogService.refreshCatalogue(engineDispatch.catalogState, engineDispatch.internalEngine)) {
          case (#err(msg)) {
            return dispatchError("Failed to fetch workflow catalog: " # msg);
          };
          case (#ok) {};
        };
        switch (WorkflowCatalogModel.getHash(engineDispatch.catalogState)) {
          case (?h) { h };
          case (null) {
            return dispatchError("Workflow catalog unavailable after refresh attempt");
          };
        };
      };
    };

    // Build envelope and dispatch
    let scopeGrants = buildScopeGrants(envelopeContext.agent);

    let { envelopeId; nonce = envelopeNonce } = ExecutionEnvelopeModel.issue(
      engineDispatch.envelopeState,
      envelopeContext.turnId,
      envelopeContext.agent.ownedBy,
      scopeGrants,
    );

    let envelope : ExecutionTypes.EnvelopePayload = {
      envelopeId;
      dispatchedVersion = null; // means not dispatched yet.
      requestId = envelopeContext.turnId;
      agentId = envelopeContext.agent.id;
      agentName = envelopeContext.agent.config.name;
      workspaceId = envelopeContext.agent.ownedBy;
      workflowId;
      model = envelopeContext.agent.config.model;
      messages = envelopeContext.messages;
      instructions = envelopeContext.instructions;
      constraints = {
        maxRounds = Constants.MAX_AGENT_ROUNDS;
        maxTokenBudget = null;
      };
      secrets = {
        apiKeys = [("openrouter", envelopeContext.apiKey)];
      };
      scopeGrants;
      envelopeNonce;
      catalogHash = ?catalogHash;
    };

    try {
      switch (await EngineDispatchService.dispatch(engineDispatch.envelopeState, engineDispatch.internalEngine, envelope)) {
        case (#ok) {
          #success(Json.stringify(obj([("dispatched", bool(true))]), null));
        };
        case (#err(e)) {
          ExecutionEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
          // If the engine signalled a stale catalog, refresh it and surface a retry hint.
          // The LLM will see this as a tool error and retry the operation on the next round.
          switch (Json.parse(e)) {
            case (#ok(errJson)) {
              switch (Json.get(errJson, "type")) {
                case (?#string("staleCatalog")) {
                  switch (await WorkflowCatalogService.refreshCatalogue(engineDispatch.catalogState, engineDispatch.internalEngine)) {
                    case (#ok) {
                      return dispatchError("Workflow catalog was updated. Please retry the operation.");
                    };
                    case (#err(refreshErr)) {
                      return dispatchError("Workflow catalog is outdated and could not be refreshed: " # refreshErr);
                    };
                  };
                };
                case (_) {};
              };
            };
            case (#err(_)) {};
          };
          dispatchError("Engine dispatch failed: " # e);
        };
      };
    } catch (e : Error) {
      ExecutionEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
      dispatchError("Engine call failed: " # Error.message(e));
    };
  };

  // ─── Scope helpers ────────────────────────────────────────────────────────────

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

  // ─── Error helper ─────────────────────────────────────────────────────────────

  private func dispatchError(msg : Text) : ToolTypes.ToolCallOutcome {
    #error(Json.stringify(obj([("dispatched", bool(false)), ("error", str(msg))]), null));
  };
};
