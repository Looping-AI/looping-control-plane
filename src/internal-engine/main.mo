import Principal "mo:core/Principal";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Json "mo:json";
import { str; obj } "mo:json";
import ExecutionTypes "./execution-types";
import CoreWrapper "./wrappers/core-wrapper";
import RunHelpers "./runner/run-helpers";
import RunStoreModel "./models/run-store-model";
import EnvelopeProcessor "./runner/envelope-processor";
import WorkflowCatalog "./workflows/workflow-catalog";

shared ({ caller = coreId }) persistent actor class InternalEngine() = self {

  let core : CoreWrapper.CoreActor = actor (Principal.toText(coreId));

  // ── Persistent state ───────────────────────────────────────────────

  let runStore = RunStoreModel.empty();

  // ── Catalog hash ───────────────────────────────────────────────────
  // Recomputed on every install/upgrade from the static descriptor list.
  // Declared transient so the initializer always runs — persistent lets
  // retain their pre-upgrade value and would silently serve a stale hash.
  transient let catalogHash : Text = WorkflowCatalog.computeHash(WorkflowCatalog.allDescriptors);

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

  // ── Error helpers ─────────────────────────────────────────────────

  private func executeError(type_ : Text, message : Text) : { #ok; #err : Text } {
    #err(Json.stringify(obj([("type", str(type_)), ("message", str(message))]), null));
  };

  // ── Catalog endpoint ──────────────────────────────────────────────
  // Returns the full workflow catalog (hash + descriptors) as a JSON string.
  // Restricted to Core — callers other than coreId receive Unauthorized.

  public shared ({ caller }) func listWorkflows() : async {
    #ok : Text;
    #err : Text;
  } {
    if (caller != coreId) { return #err("Unauthorized") };
    #ok(WorkflowCatalog.listWorkflowsJson(catalogHash));
  };

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

    // Catalog hash check — Core must always send the hash it received from listWorkflows().
    // A missing hash means Core hasn't fetched the catalog yet (Phase 2 not deployed).
    // A mismatched hash means the catalog was updated; Core must refetch and retry.
    switch (envelope.catalogHash) {
      case (null) {
        return executeError(
          "missingCatalogHash",
          "Envelope is missing the required catalog hash. Fetch listWorkflows() and include the catalogHash on every execute() call.",
        );
      };
      case (?h) {
        if (h != catalogHash) {
          return executeError(
            "staleCatalog",
            "Workflow catalog is outdated. Fetch listWorkflows() to get the current catalog and catalogHash, then retry.",
          );
        };
      };
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
