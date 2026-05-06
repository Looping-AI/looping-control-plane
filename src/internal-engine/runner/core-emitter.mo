/// Core Emitter
/// Sends workflow events (complete, milestone) to the Core canister via workflowApi.
/// Extracted from workflow-runner.mo so the runner can focus purely on execution
/// and the caller owns the emit step.

import Array "mo:core/Array";
import List "mo:core/List";
import Error "mo:core/Error";
import Json "mo:json";
import { str; arr; int; float; bool; obj } "mo:json";
import WorkflowTypes "../workflow-types";
import CoreWrapper "../wrappers/core-wrapper";

module {

  /// Emit a final completion event to Core.
  /// Called once per execution, after the runner returns its RunOutcome.
  public func emitComplete(
    wrapper : CoreWrapper.CoreWrapper,
    humanSummary : Text,
    stepsDetail : [WorkflowTypes.SummarizedStep],
    status : WorkflowTypes.WorkflowStatus,
    stats : WorkflowTypes.WorkflowStats,
  ) : async { #ok : Text; #err : Text } {
    let fields = List.empty<(Text, Json.Json)>();
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
      await wrapper.callCore(#post, "/workflow/complete", body);
    } catch (e : Error) {
      #err("Failed to emit complete: " # Error.message(e));
    };
  };

  /// Emit a mid-loop milestone event to Core.
  /// Called from inside the runner after meaningful tool-call rounds.
  /// Non-fatal — the runner catches failures and continues execution.
  public func emitMilestone(
    wrapper : CoreWrapper.CoreWrapper,
    humanSummary : Text,
    stepsDetail : [WorkflowTypes.SummarizedStep],
  ) : async { #ok : Text; #err : Text } {
    let body = Json.stringify(
      obj([
        ("humanSummary", str(humanSummary)),
        ("stepsDetail", stepsToJson(stepsDetail)),
      ]),
      null,
    );
    try {
      await wrapper.callCore(#post, "/workflow/milestone", body);
    } catch (e : Error) {
      #err("Failed to emit milestone: " # Error.message(e));
    };
  };

  // ── Serialization helpers ──────────────────────────────────────────

  func stepsToJson(steps : [WorkflowTypes.SummarizedStep]) : Json.Json {
    arr(
      Array.map<WorkflowTypes.SummarizedStep, Json.Json>(
        steps,
        func(s : WorkflowTypes.SummarizedStep) : Json.Json {
          obj([
            ("tool", str(s.tool)),
            ("summary", str(s.summary)),
            ("success", bool(s.success)),
          ]);
        },
      )
    );
  };

  func statusToJson(status : WorkflowTypes.WorkflowStatus) : Json.Json {
    switch (status) {
      case (#completed) { str("completed") };
      case (#failed(_)) { str("failed") };
      case (#roundLimitReached) { str("roundLimitReached") };
    };
  };

  func statsToJson(stats : WorkflowTypes.WorkflowStats) : Json.Json {
    let fields = List.empty<(Text, Json.Json)>();
    switch (stats.durationNs) {
      case (?v) { List.add(fields, ("durationNs", int(v))) };
      case (null) {};
    };
    switch (stats.llmCalls) {
      case (?v) { List.add(fields, ("llmCalls", int(v))) };
      case (null) {};
    };
    switch (stats.toolCalls) {
      case (?v) { List.add(fields, ("toolCalls", int(v))) };
      case (null) {};
    };
    switch (stats.inputTokens) {
      case (?v) { List.add(fields, ("inputTokens", int(v))) };
      case (null) {};
    };
    switch (stats.outputTokens) {
      case (?v) { List.add(fields, ("outputTokens", int(v))) };
      case (null) {};
    };
    switch (stats.model) {
      case (?v) { List.add(fields, ("model", str(v))) };
      case (null) {};
    };
    switch (stats.rounds) {
      case (?v) { List.add(fields, ("rounds", int(v))) };
      case (null) {};
    };
    switch (stats.estimatedDollarCost) {
      case (?cost) { List.add(fields, ("estimatedDollarCost", float(cost))) };
      case (null) {};
    };
    obj(List.toArray(fields));
  };

};
