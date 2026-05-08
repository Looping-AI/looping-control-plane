import Principal "mo:core/Principal";
import Cycles "mo:core/Cycles";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Json "mo:json";
import { str; obj } "mo:json";
import WorkflowTypes "./workflow-types";
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
    if (caller != coreId) {
      return #err(Json.stringify(obj([("type", str("unauthorized")), ("message", str("Unauthorized."))]), null));
    };
    #ok(WorkflowCatalog.listWorkflowsJson(catalogHash));
  };

  // ── Execute (ingress) ─────────────────────────────────────────────
  // Validates, enqueues into the run store, fires a zero-delay timer,
  // and returns immediately. The LLM loop runs asynchronously via the
  // timer and delivers results to Core via emitComplete / emitMilestone.

  public shared ({ caller }) func execute(envelope : WorkflowTypes.EnvelopePayload) : async {
    #ok;
    #err : Text;
  } {
    if (caller != coreId) {
      return executeError("unauthorized", "Unauthorized.");
    };

    // Version check — reject envelopes with an unknown or missing dispatchedVersion.
    // Error body follows the shared JSON protocol: {"type":"versionMismatch","message":"...","envelopeVersionRequired":"v1"}
    // The extra "envelopeVersionRequired" field lets Core parse the required version for automatic retry.
    let versionOk = switch (envelope.dispatchedVersion) {
      case (?v) { v == envelopeVersion };
      case (null) { false };
    };
    if (not versionOk) {
      return #err(Json.stringify(obj([("type", str("versionMismatch")), ("message", str("Envelope version mismatch. Engine requires: " # envelopeVersion # ".")), ("envelopeVersionRequired", str(envelopeVersion))]), null));
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
      return executeError("missingApiKey", "Missing 'openrouter' API key in envelope secrets.");
    };

    // Build run record and enqueue
    let record = RunHelpers.fromEnvelope(envelope, Time.now());
    switch (RunStoreModel.enqueue(runStore, record)) {
      case (#duplicate) {
        return executeError("duplicateEnvelopeId", "Duplicate envelopeId: " # Nat.toText(envelope.envelopeId));
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

  // ── Cycle recovery ────────────────────────────────────────────────

  type IC = actor {
    deposit_cycles : shared { canister_id : Principal } -> async ();
  };

  transient let ic : IC = actor ("aaaaa-aa");

  /// Called by Core before stopping and deleting this canister.
  /// Transfers available cycles (minus a small buffer) back to Core.
  public shared ({ caller }) func recoverAvailableCycles() : async () {
    assert caller == coreId;
    let balance : Nat = Cycles.balance();
    let buffer : Nat = 100_000_000_000;
    if (balance > buffer) {
      let available : Nat = balance - buffer;
      await (with cycles = available) ic.deposit_cycles({
        canister_id = coreId;
      });
    };
  };

};
