import Principal "mo:core/Principal";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import ExecutionTypes "./execution-types";
import CoreWrapper "./wrappers/core-wrapper";
import RunHelpers "./runner/run-helpers";
import RunStoreModel "./models/run-store-model";
import EnvelopeProcessor "./runner/envelope-processor";

shared ({ caller = coreId }) persistent actor class InternalEngine() = self {

  let core : CoreWrapper.CoreActor = actor (Principal.toText(coreId));

  // ── Persistent state ───────────────────────────────────────────────

  let runStore = RunStoreModel.empty();

  // ── Envelope version ──────────────────────────────────────────────
  // The envelope format version this engine requires.
  // Format: "v1", "v1.1" — major = breaking field changes, minor = additive.
  // On mismatch Core receives a JSON error body and retries with the required version.
  let envelopeVersion : Text = "v1";

  // ── Periodic run-store maintenance ────────────────────────────────
  // Runs every week: prunes completed/failed records.
  ignore Timer.recurringTimer<system>(
    #seconds(604800),
    func() : async () {
      ignore RunStoreModel.purgeCompleted(runStore);
      ignore RunStoreModel.purgeOldFailed(runStore);
    },
  );

  // ── Execute (ingress) ─────────────────────────────────────────────
  // Validates, enqueues into the run store, fires a zero-delay timer,
  // and returns immediately. The LLM loop runs asynchronously via the
  // timer and delivers results to Core via emitComplete / emitMilestone.

  public shared ({ caller }) func execute(envelope : ExecutionTypes.EnvelopePayload) : async {
    #ok;
    #err : Text;
  } {
    if (caller != coreId) { return #err("Unauthorized") };

    // Version check — reject envelopes with an unknown or missing dispatchedVersion.
    // Error body follows the shared JSON protocol so HTTP engines can use the same contract:
    //   {"envelopeVersionRequired":"v1"}
    let versionOk = switch (envelope.dispatchedVersion) {
      case (?v) { v == envelopeVersion };
      case (null) { false };
    };
    if (not versionOk) {
      return #err("{\"envelopeVersionRequired\":\"" # envelopeVersion # "\"}");
    };

    // Validate before accepting — fail fast for missing credentials
    let hasApiKey = Array.find<(Text, Text)>(
      envelope.secrets.apiKeys,
      func(kv : (Text, Text)) : Bool { kv.0 == "openrouter" },
    ) != null;
    if (not hasApiKey) {
      return #err("Missing 'openrouter' API key in envelope secrets");
    };

    // Build run record and enqueue
    let record = RunHelpers.fromEnvelope(envelope, Time.now());
    switch (RunStoreModel.enqueue(runStore, record)) {
      case (#duplicate) {
        return #err("Duplicate envelopeId: " # Nat.toText(envelope.envelopeId));
      };
      case (#ok) {};
    };

    let envelopeId = envelope.envelopeId;
    ignore Timer.setTimer<system>(
      #nanoseconds 0,
      func() : async () {
        await EnvelopeProcessor.process(core, envelopeId, runStore);
      },
    );
    #ok;
  };

};
