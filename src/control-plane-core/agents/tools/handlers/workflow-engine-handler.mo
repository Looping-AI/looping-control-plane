import Json "mo:json";
import { str; obj; bool } "mo:json";
import Error "mo:core/Error";
import AgentHelpers "../../../agents/helpers";
import JsonPretty "../../../utilities/json-pretty";
import WorkflowTypes "../../../types/workflow";
import WorkflowEnvelopeModel "../../../models/workflow-envelope-model";
import WorkflowCatalogModel "../../../models/workflow-catalog-model";
import WorkflowCatalogService "../../../services/workflow-catalog-service";
import WorkflowCatalogTypes "../../../types/workflow-catalog";
import ApprovalModel "../../../models/approval-model";
import Constants "../../../constants";
import SlackWrapper "../../../wrappers/slack-wrapper";
import EngineDispatchService "../../../services/engine-dispatch-service";
import SessionModel "../../../models/session-model";
import ToolTypes "../tool-types";

module {

  // ─── Handler ─────────────────────────────────────────────────────────────────

  /// Dispatch a single workflow descriptor to the engine.
  ///
  /// Processes coreDirectives before any envelope is issued:
  ///   #require("approval") — if approvalCode absent: generates code, posts Slack prompt,
  ///     returns #ok({dispatched:false,approvalRequired:true,approvalCode}).
  ///     If approvalCode present: proceeds to dispatch.
  ///   #preValidation(rules) — validates slack_channel_exists rules via SlackWrapper.
  ///
  /// Returns #ok("{\"dispatched\":true}") on success so the orchestrator can
  /// detect the dispatch signal uniformly (like any other tool result).
  /// Returns #err with structured JSON {"type":"camelCase","message":"..."} on failure.
  public func handle(
    descriptor : WorkflowCatalogTypes.WorkflowDescriptor,
    engineDispatch : ToolTypes.EngineDispatch,
    envelopeContext : ToolTypes.EnvelopeContext,
    resolveSlackBotToken : ?(Text -> ?Text),
    requestedByUserId : Text,
    sourceRef : ?SessionModel.SourceRef,
    args : Text,
  ) : async ToolTypes.ToolCallOutcome {
    // 1. Parse arguments
    let parsed = switch (Json.parse(args)) {
      case (#err(_)) {
        return handlerError("parseError", "Invalid JSON arguments for " # descriptor.workflowName);
      };
      case (#ok(json)) { json };
    };

    // 2. Process coreDirectives
    for (directive in descriptor.coreDirectives.vals()) {
      switch (directive) {
        case (#require("approval")) {
          switch (Json.get(parsed, "approvalCode")) {
            case (?#string(code)) {
              if (not isAcceptedApprovalCode(engineDispatch.approvalState, code, descriptor, envelopeContext, requestedByUserId)) {
                return handlerError("invalidApprovalCode", "Approval code has not been accepted for this workflow.");
              };
            };
            case (_) {
              // No approval code: generate one, post Slack Block Kit prompt, return approval signal.
              let renderedArgs = JsonPretty.prettyPrint(parsed, 0);
              let approvalCode = ApprovalModel.request(
                engineDispatch.approvalState,
                descriptor.workflowName,
                args,
                envelopeContext.agent.ownedBy,
                envelopeContext.agent.id,
                envelopeContext.turnId,
                requestedByUserId,
              );
              // Plain-text fallback shown in notifications and clients that don't support Block Kit.
              let slackTextFallback = "Workflow `" # descriptor.workflowName # "` requires your approval — use the buttons below to approve or deny.";
              // Block Kit: section with details + Approve / Deny action buttons.
              let blocksJson = Json.stringify(
                #array([
                  obj([
                    ("type", str("section")),
                    (
                      "text",
                      obj([
                        ("type", str("mrkdwn")),
                        ("text", str("*Approval required* — workflow `" # descriptor.workflowName # "`\n\n*Arguments:*\n```\n" # renderedArgs # "\n```")),
                      ]),
                    ),
                  ]),
                  obj([
                    ("type", str("actions")),
                    (
                      "elements",
                      #array([
                        obj([
                          ("type", str("button")),
                          ("text", obj([("type", str("plain_text")), ("text", str("Approve"))])),
                          ("style", str("primary")),
                          ("action_id", str("approve_workflow")),
                          ("value", str(approvalCode)),
                        ]),
                        obj([
                          ("type", str("button")),
                          ("text", obj([("type", str("plain_text")), ("text", str("Deny"))])),
                          ("style", str("danger")),
                          ("action_id", str("deny_workflow")),
                          ("value", str(approvalCode)),
                        ]),
                      ]),
                    ),
                  ]),
                ]),
                null,
              );
              switch (resolveSlackBotToken) {
                case (?resolve) {
                  switch (resolve("approval/" # descriptor.workflowName)) {
                    case (?token) {
                      switch (sourceRef) {
                        case (?#slack({ channelId; ts = _; threadTs })) {
                          ignore await SlackWrapper.postMessage(token, channelId, slackTextFallback, threadTs, null, ?blocksJson);
                        };
                        case (_) {}; // non-Slack source — approval prompt cannot be posted
                      };
                    };
                    case (null) {}; // no token — code still returned, Slack message skipped
                  };
                };
                case (null) {}; // no resolver — same fallback
              };
              return #ok(Json.stringify(obj([("dispatched", bool(false)), ("approvalRequired", bool(true)), ("approvalCode", str(approvalCode))]), null));
            };
          };
        };
        case (#preValidation(rules)) {
          for (rule in rules.vals()) {
            switch (rule.rule) {
              case "slack_channel_exists" {
                let channelId = switch (Json.get(parsed, rule.param)) {
                  case (?#string(id)) { id };
                  case (_) {
                    return handlerError(
                      "missingField",
                      "Missing required parameter '" # rule.param # "' for pre-validation",
                    );
                  };
                };
                let token = switch (resolveSlackBotToken) {
                  case (?resolve) {
                    switch (resolve("pre-validation/" # descriptor.workflowName)) {
                      case (?t) { t };
                      case (null) {
                        return handlerError("configError", "Slack bot token not configured");
                      };
                    };
                  };
                  case (null) {
                    return handlerError("configError", "Slack bot token resolver not available");
                  };
                };
                switch (await SlackWrapper.getChannelInfo(token, channelId)) {
                  case (#ok(_)) {}; // channel exists — proceed
                  case (#err(msg)) {
                    return handlerError(
                      "channelNotFound",
                      "Channel '" # channelId # "' not found: " # msg,
                    );
                  };
                };
              };
              case _ {}; // unknown rule — silently skip for forward compat
            };
          };
        };
        case (#require(_)) {}; // unknown require value — silently skip for forward compat
      };
    };

    // 3. Catalog hash — lazy refresh if cache is null
    let catalogHash = switch (WorkflowCatalogModel.getHash(engineDispatch.catalogState)) {
      case (?h) { h };
      case (null) {
        switch (await WorkflowCatalogService.refreshCatalog(engineDispatch.catalogState, engineDispatch.internalEngine)) {
          case (#err(msg)) {
            return handlerError("catalogError", "Failed to fetch workflow catalog: " # msg);
          };
          case (#ok) {};
        };
        switch (WorkflowCatalogModel.getHash(engineDispatch.catalogState)) {
          case (?h) { h };
          case (null) {
            return handlerError("catalogError", "Workflow catalog unavailable after refresh attempt");
          };
        };
      };
    };

    // 4. Issue envelope
    let scopeGrants = AgentHelpers.buildScopeGrants(envelopeContext.agent);
    let { envelopeId; nonce = envelopeNonce } = WorkflowEnvelopeModel.issue(
      engineDispatch.envelopeState,
      envelopeContext.turnId,
      envelopeContext.agent.ownedBy,
      scopeGrants,
    );

    // 5. Build payload
    let envelope : WorkflowTypes.EnvelopePayload = {
      envelopeId;
      dispatchedVersion = null;
      catalogHash = ?catalogHash;
      requestId = envelopeContext.turnId;
      agentId = envelopeContext.agent.id;
      agentName = envelopeContext.agent.config.name;
      workspaceId = envelopeContext.agent.ownedBy;
      workflowName = descriptor.workflowName;
      workflowArguments = if (args == "" or args == "{}") { null } else {
        ?args;
      };
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
    };

    // 6. Dispatch to engine
    try {
      switch (await EngineDispatchService.dispatch(engineDispatch.envelopeState, engineDispatch.internalEngine, envelope)) {
        case (#ok) {
          #ok(Json.stringify(obj([("dispatched", bool(true))]), null));
        };
        case (#err(e)) {
          WorkflowEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
          // If the engine signalled a stale catalog, refresh and surface a retry hint.
          switch (Json.parse(e)) {
            case (#ok(errJson)) {
              switch (Json.get(errJson, "type")) {
                case (?#string("staleCatalog")) {
                  switch (await WorkflowCatalogService.refreshCatalog(engineDispatch.catalogState, engineDispatch.internalEngine)) {
                    case (#ok) {
                      return handlerError("staleCatalog", "Workflow catalog was updated. Please retry the operation.");
                    };
                    case (#err(refreshErr)) {
                      return handlerError("catalogError", "Workflow catalog is outdated and could not be refreshed: " # refreshErr);
                    };
                  };
                };
                case (_) {};
              };
            };
            case (#err(_)) {};
          };
          handlerError("dispatchFailed", "Engine dispatch failed: " # e);
        };
      };
    } catch (e : Error) {
      WorkflowEnvelopeModel.revoke(engineDispatch.envelopeState, envelopeNonce);
      handlerError("dispatchFailed", "Engine call failed: " # Error.message(e));
    };
  };

  // ─── Error helper ─────────────────────────────────────────────────────────────

  private func handlerError(errType : Text, msg : Text) : ToolTypes.ToolCallOutcome {
    #err(Json.stringify(obj([("type", str(errType)), ("message", str(msg))]), null));
  };

  private func isAcceptedApprovalCode(
    approvalState : ApprovalModel.ApprovalState,
    code : Text,
    descriptor : WorkflowCatalogTypes.WorkflowDescriptor,
    envelopeContext : ToolTypes.EnvelopeContext,
    requestedByUserId : Text,
  ) : Bool {
    switch (ApprovalModel.findByCode(approvalState, code)) {
      case null { false };
      case (?record) {
        if (record.workflowName != descriptor.workflowName) return false;
        if (record.turnId != envelopeContext.turnId) return false;
        if (record.workspaceId != envelopeContext.agent.ownedBy) return false;
        if (record.agentId != envelopeContext.agent.id) return false;
        if (record.requestedByUserId != requestedByUserId) return false;
        switch (record.status) {
          case (#approved) { true };
          case (_) { false };
        };
      };
    };
  };
};
