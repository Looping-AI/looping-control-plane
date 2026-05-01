import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Error "mo:core/Error";
import Types "../types";
import SessionModel "../models/session-model";
import AgentModel "../models/agent-model";
import WorkspaceModel "../models/workspace-model";
import SecretModel "../models/secret-model";
import KeyDerivationService "key-derivation-service";
import ExecutionTypes "../types/execution";
import SlackWrapper "../wrappers/slack-wrapper";
import Logger "../utilities/logger";

module {

  // ── Dependencies (captured at construction time — all stable let-bindings) ──

  public type ServiceDeps = {
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    workspaces : WorkspaceModel.WorkspacesState;
    secrets : SecretModel.SecretsState;
    resumeAdminTurn : (turnId : Text, suspension : SessionModel.SuspensionData, syntheticToolResult : Text) -> async Types.AgentOrchestrateResult;
  };

  public class Service(deps : ServiceDeps) {

    /// Process a single execution async effect — posts results to Slack and completes turns.
    /// `keyCache` is passed at call time (not captured in deps) because it is a transient
    /// var in main.mo that may be replaced by the 30-day key-rotation timer; capturing it
    /// at construction would leave the service with a stale reference after rotation.
    public func processEffect(
      keyCache : KeyDerivationService.KeyCache,
      effect : ExecutionTypes.AsyncEffect,
    ) : async () {
      let (envelopeId, turnId, humanSummary) = switch (effect) {
        case (#milestone(m)) { (m.envelopeId, m.turnId, m.humanSummary) };
        case (#complete(c)) { (c.envelopeId, c.turnId, c.humanSummary) };
      };

      // Look up the turn to get source context
      let turn = switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
        case (?t) { t };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Turn not found: " # turnId # " (envelope=" # Nat.toText(envelopeId) # ")");
          return;
        };
      };

      // Look up agent for metadata and workspace context
      let agent = switch (AgentModel.lookupById(deps.agentRegistry, turn.agentId)) {
        case (?a) { a };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Agent not found: " # Nat.toText(turn.agentId));
          return;
        };
      };

      // For non-Slack sources (timer, GitHub, etc.), fall back to the agent's workspace
      // admin channel so execution is observable rather than silently lost.
      // ts and threadTs are null since there is no parent message to thread under.
      let (channelId, ts, threadTs) = switch (turn.sourceRef) {
        case (?#slack(s)) { (s.channelId, s.ts, s.threadTs) };
        case (_) {
          let adminChannel = switch (WorkspaceModel.getWorkspace(deps.workspaces, agent.ownedBy)) {
            case (?ws) { ws.adminChannelId };
            case null { null };
          };
          switch (adminChannel) {
            case (?ch) { (ch, "", null) };
            case null {
              Logger.log(#error, ?"ExecutionAsyncEffect", "No admin channel for non-Slack turn " # turnId # " — cannot post result");
              return;
            };
          };
        };
      };

      // Derive bot token
      let orgKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
      let botToken = switch (
        SecretModel.resolvePlatformSecret(
          deps.secrets,
          orgKey,
          null,
          #slackBotToken,
          {
            slackUserId = null;
            agentId = null;
            operation = "async-effect:bot-token";
          },
        )
      ) {
        case (?t) { t };
        case null {
          Logger.log(#error, ?"ExecutionAsyncEffect", "Bot token not available for turn " # turnId);
          return;
        };
      };

      // Build metadata matching the message-handler pattern
      let metadata : ?Types.AgentMessageMetadata = ?{
        event_type = "looping_agent_message";
        event_payload = {
          parent_agent = agent.config.name;
          parent_ts = ts;
          parent_channel = channelId;
          turn_id = turnId;
        };
      };

      switch (effect) {
        case (#milestone(_m)) {
          // Post milestone update to Slack thread
          switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata)) {
            case (#ok(_)) {};
            case (#err(e)) {
              Logger.log(#error, ?"ExecutionAsyncEffect", "Milestone post failed for turn " # turnId # ": " # e);
            };
          };
        };
        case (#complete(c)) {
          switch (turn.status) {
            case (#awaitingWorkflow(suspension)) {
              // Resume: inject the engine result as a synthetic tool result and continue the LLM loop.
              let syntheticResult = buildSyntheticToolResult(c);
              let resumeResult = try {
                await deps.resumeAdminTurn(turnId, suspension, syntheticResult);
              } catch (e) {
                Logger.log(#error, ?"ExecutionAsyncEffect", "resumeAdminTurn threw for turn " # turnId # ": " # Error.message(e));
                let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
                SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?"Resume call failed");
                return;
              };
              switch (resumeResult) {
                case (#ok({ response; steps = _ })) {
                  // Post the LLM response from the resumed loop.
                  switch (await SlackWrapper.postMessage(botToken, channelId, response, threadTs, metadata)) {
                    case (#ok({ ts = replyTs; channel = _ })) {
                      SessionModel.appendTrace(
                        deps.sessionStores,
                        turnId,
                        #slackPost({ channelId; threadTs; ts = replyTs }),
                      );
                    };
                    case (#err(e)) {
                      Logger.log(#error, ?"ExecutionAsyncEffect", "Reply post failed after resume for turn " # turnId # ": " # e);
                    };
                  };
                  let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
                  SessionModel.completeTurn(deps.sessionStores, turnId, #succeeded, cost, null);
                };
                case (#dispatched({ steps = _; suspension = newSuspension })) {
                  // Resumed loop dispatched another workflow — suspend again.
                  turn.status := #awaitingWorkflow(newSuspension);
                };
                case (#err({ message; steps = _ })) {
                  let errorText = "[Agent error] " # message;
                  switch (await SlackWrapper.postMessage(botToken, channelId, errorText, threadTs, metadata)) {
                    case (#ok(_)) {};
                    case (#err(e)) {
                      Logger.log(#error, ?"ExecutionAsyncEffect", "Error post failed after resume for turn " # turnId # ": " # e);
                    };
                  };
                  let cost = SessionModel.aggregateTurnCost(deps.sessionStores, turnId);
                  SessionModel.completeTurn(deps.sessionStores, turnId, #failed, cost, ?message);
                };
              };
            };
            case (_) {
              // Normal (non-resume) completion: post humanSummary and mark turn terminal.
              switch (await SlackWrapper.postMessage(botToken, channelId, humanSummary, threadTs, metadata)) {
                case (#ok({ ts = replyTs; channel = _ })) {
                  SessionModel.appendTrace(
                    deps.sessionStores,
                    turnId,
                    #slackPost({
                      channelId;
                      threadTs;
                      ts = replyTs;
                    }),
                  );
                };
                case (#err(e)) {
                  Logger.log(#error, ?"ExecutionAsyncEffect", "Reply post failed for turn " # turnId # ": " # e);
                };
              };

              let (turnStatus, errorSummary) = switch (c.status) {
                case (#completed) { (#succeeded, null) };
                case (#failed(reason)) { (#failed, ?reason) };
                case (#roundLimitReached) { (#failed, ?"Round limit reached") };
              };

              let turnCost : ?SessionModel.TurnCost = switch (c.stats.inputTokens, c.stats.outputTokens) {
                case (?inp, ?out) {
                  ?{
                    promptTokens = inp;
                    completionTokens = out;
                    estimatedDollarCost = c.stats.estimatedDollarCost;
                  };
                };
                case (_) { null };
              };

              SessionModel.completeTurn(deps.sessionStores, turnId, turnStatus, turnCost, errorSummary);
            };
          };
        };
      };
    };
  };

  /// Build the synthetic tool result JSON injected into the LLM conversation on resume.
  private func buildSyntheticToolResult(
    c : {
      humanSummary : Text;
      stepsDetail : [ExecutionTypes.SummarizedStep];
      status : ExecutionTypes.ExecutionStatus;
      stats : ExecutionTypes.ExecutionStats;
    }
  ) : Text {
    let statusText = switch (c.status) {
      case (#completed) { "completed" };
      case (#failed(_)) { "failed" };
      case (#roundLimitReached) { "roundLimitReached" };
    };

    let stepsJson = Text.join(
      Array.map<ExecutionTypes.SummarizedStep, Text>(
        c.stepsDetail,
        func(s : ExecutionTypes.SummarizedStep) : Text {
          "{\"tool\":\"" # s.tool # "\",\"summary\":\"" # escapeJson(s.summary) # "\",\"success\":" # (if (s.success) "true" else "false") # "}";
        },
      ).vals(),
      ",",
    );

    let durationStr = switch (c.stats.durationNs) {
      case (?d) { Int.toText(d) };
      case null { "null" };
    };
    let llmCallsStr = switch (c.stats.llmCalls) {
      case (?n) { Nat.toText(n) };
      case null { "null" };
    };
    let inputTokensStr = switch (c.stats.inputTokens) {
      case (?n) { Nat.toText(n) };
      case null { "null" };
    };
    let outputTokensStr = switch (c.stats.outputTokens) {
      case (?n) { Nat.toText(n) };
      case null { "null" };
    };
    let costStr = switch (c.stats.estimatedDollarCost) {
      case (?f) { Float.toText(f) };
      case null { "null" };
    };

    "{\"status\":\"" # statusText # "\",\"humanSummary\":\"" # escapeJson(c.humanSummary) # "\",\"stepsDetail\":[" # stepsJson # "],\"stats\":{\"durationNs\":" # durationStr # ",\"llmCalls\":" # llmCallsStr # ",\"inputTokens\":" # inputTokensStr # ",\"outputTokens\":" # outputTokensStr # ",\"estimatedDollarCost\":" # costStr # "}}";
  };

  /// Escape a string for embedding inside a JSON string value.
  private func escapeJson(s : Text) : Text {
    var result = "";
    for (c in s.chars()) {
      let escaped = if (c == '\"') { "\\\"" } else if (c == '\\') { "\\\\" } else if (c == '\n') {
        "\\n";
      } else if (c == '\r') { "\\r" } else if (c == '\t') { "\\t" } else {
        Text.fromChar(c);
      };
      result #= escaped;
    };
    result;
  };
};
