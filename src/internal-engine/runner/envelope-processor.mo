/// Envelope Processor
/// Owns the full lifecycle of a single execution run after it has been enqueued:
///   1. Claims the run from the store
///   2. Delegates to ExecutionRunner to get a RunOutcome
///   3. Applies the outcome to the run store
///   4. Emits the final result to Core via CoreEmitter
///
/// All exit paths — including traps — are handled here in one place.
/// Extracted from main.mo so this logic is independently testable.

import Error "mo:core/Error";
import ExecutionTypes "../execution-types";
import CoreWrapper "../wrappers/core-wrapper";
import RunStoreModel "../models/run-store-model";
import ExecutionRunner "./execution-runner";
import CoreEmitter "./core-emitter";

module {

  /// Process a single enqueued envelope to completion.
  /// Idempotent — if the run has already been claimed or is missing, returns immediately.
  public func process(
    core : CoreWrapper.CoreActor,
    envelopeId : Nat,
    runStore : RunStoreModel.RunStoreState,
  ) : async () {

    // Claim the run — if already claimed or missing, nothing to do
    let record = switch (RunStoreModel.claim(runStore, envelopeId)) {
      case (null) { return };
      case (?r) { r };
    };

    let envelope = record.envelope;
    let wrapper = CoreWrapper.CoreWrapper(core, envelope.envelopeNonce);

    // ── Execute ────────────────────────────────────────────────────────
    let outcome = try {
      await ExecutionRunner.run(wrapper, envelope);
    } catch (e : Error) {
      // Trap or unexpected error — mark failed in the store and notify Core
      let errMsg = "Trap: " # Error.message(e);
      RunStoreModel.markFailed(runStore, envelopeId, errMsg, []);
      let emitResult = try {
        switch (await CoreEmitter.emitComplete(wrapper, errMsg, [], #failed(errMsg), zeroStats())) {
          case (#ok(_)) { #ok };
          case (#err(msg)) { #err(msg) };
        };
      } catch (_emitErr : Error) { #err("emit failed after trap") };
      RunStoreModel.setEmitResult(runStore, envelopeId, emitResult);
      return;
    };

    // ── Apply outcome to the run store ─────────────────────────────────
    switch (outcome.status) {
      case (#completed) {
        RunStoreModel.markCompleted(runStore, envelopeId, #completed, outcome.stats, outcome.steps);
      };
      case (#roundLimitReached) {
        RunStoreModel.markCompleted(runStore, envelopeId, #roundLimitReached, outcome.stats, outcome.steps);
      };
      case (#failed(reason)) {
        RunStoreModel.markFailed(runStore, envelopeId, reason, outcome.steps);
      };
    };

    // ── Emit final result to Core ──────────────────────────────────────
    let emitResult = try {
      switch (await CoreEmitter.emitComplete(wrapper, outcome.humanSummary, outcome.summarizedSteps, outcome.status, outcome.stats)) {
        case (#ok(_)) { #ok };
        case (#err(msg)) { #err(msg) };
      };
    } catch (e : Error) { #err("emit failed: " # Error.message(e)) };
    RunStoreModel.setEmitResult(runStore, envelopeId, emitResult);
  };

  // ── Private helpers ────────────────────────────────────────────────

  /// Null stats used in the trap path where no execution data is available.
  func zeroStats() : ExecutionTypes.ExecutionStats {
    {
      durationNs = null;
      llmCalls = null;
      toolCalls = null;
      inputTokens = null;
      outputTokens = null;
      model = null;
      rounds = null;
      estimatedDollarCost = null;
    };
  };

};
