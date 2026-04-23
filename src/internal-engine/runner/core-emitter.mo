/// Core Emitter
/// Sends execution events (complete, milestone) to the Core canister via executionApi.
/// Extracted from execution-runner.mo so the runner can focus purely on execution
/// and the caller owns the emit step.

import Array "mo:core/Array";
import List "mo:core/List";
import Error "mo:core/Error";
import Json "mo:json";
import { str; arr; int; float; bool; obj } "mo:json";
import ExecutionTypes "../execution-types";
import CoreApi "../wrappers/core-api";

module {

  /// Emit a final completion event to Core.
  /// Called once per execution, after the runner returns its RunOutcome.
  public func emitComplete(
    core : CoreApi.CoreApi,
    envelopeNonce : Text,
    humanSummary : Text,
    stepsDetail : [ExecutionTypes.SummarizedStep],
    status : ExecutionTypes.ExecutionStatus,
    stats : ExecutionTypes.ExecutionStats,
  ) : async { #ok : Text; #err : Text } {
    let fields = List.empty<(Text, Json.Json)>();
    List.add(fields, ("envelopeNonce", str(envelopeNonce)));
    List.add(fields, ("humanSummary", str(humanSummary)));
    List.add(fields, ("stepsDetail", stepsToJson(stepsDetail)));
    List.add(fields, ("status", statusToJson(status)));
    switch (status) {
      case (#failed(reason)) { List.add(fields, ("statusReason", str(reason))) };
      case (_) {};
    };
    List.add(fields, ("stats", statsToJson(stats)));
    let body = Json.stringify(obj(List.toArray(fields)), null);
    try {
      await core.executionApi(#post, "/execution/complete", body);
    } catch (e : Error) {
      #err("Failed to emit complete: " # Error.message(e));
    };
  };

  /// Emit a mid-loop milestone event to Core.
  /// Called from inside the runner after meaningful tool-call rounds.
  /// Non-fatal — the runner catches failures and continues execution.
  public func emitMilestone(
    core : CoreApi.CoreApi,
    envelopeNonce : Text,
    humanSummary : Text,
    stepsDetail : [ExecutionTypes.SummarizedStep],
  ) : async { #ok : Text; #err : Text } {
    let body = Json.stringify(
      obj([
        ("envelopeNonce", str(envelopeNonce)),
        ("humanSummary", str(humanSummary)),
        ("stepsDetail", stepsToJson(stepsDetail)),
      ]),
      null,
    );
    try {
      await core.executionApi(#post, "/execution/milestone", body);
    } catch (e : Error) {
      #err("Failed to emit milestone: " # Error.message(e));
    };
  };

  // ── Serialization helpers ──────────────────────────────────────────

  func stepsToJson(steps : [ExecutionTypes.SummarizedStep]) : Json.Json {
    arr(
      Array.map<ExecutionTypes.SummarizedStep, Json.Json>(
        steps,
        func(s : ExecutionTypes.SummarizedStep) : Json.Json {
          obj([
            ("tool", str(s.tool)),
            ("summary", str(s.summary)),
            ("success", bool(s.success)),
          ]);
        },
      )
    );
  };

  func statusToJson(status : ExecutionTypes.ExecutionStatus) : Json.Json {
    switch (status) {
      case (#completed) { str("completed") };
      case (#failed(_)) { str("failed") };
      case (#roundLimitReached) { str("roundLimitReached") };
    };
  };

  func statsToJson(stats : ExecutionTypes.ExecutionStats) : Json.Json {
    let fields = List.empty<(Text, Json.Json)>();
    List.add(fields, ("durationNs", int(stats.durationNs)));
    List.add(fields, ("llmCalls", int(stats.llmCalls)));
    List.add(fields, ("toolCalls", int(stats.toolCalls)));
    List.add(fields, ("inputTokens", int(stats.inputTokens)));
    List.add(fields, ("outputTokens", int(stats.outputTokens)));
    List.add(fields, ("model", str(stats.model)));
    List.add(fields, ("rounds", int(stats.rounds)));
    switch (stats.estimatedDollarCost) {
      case (?cost) { List.add(fields, ("estimatedDollarCost", float(cost))) };
      case (null) {};
    };
    obj(List.toArray(fields));
  };

};
