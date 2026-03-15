import Map "mo:core/Map";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Result "mo:core/Result";
import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Array "mo:core/Array";
import Time "mo:core/Time";
import Types "../types";
import Constants "../constants";
import Encryption "../utilities/encryption";
import AgentModel "./agent-model";

module {
  /// Type alias for encrypted secret storage
  /// The Blob contains: [nonce (8 bytes)] [ciphertext]
  public type EncryptedSecret = Blob;

  // ============================================
  // Audit types
  // ============================================

  /// Who triggered a secret operation.
  public type SecretRequester = {
    slackUserId : ?Text; // from uac.slackUserId; null for timers + canister init
    agentId : ?Nat; // agent.id when inside orchestrator; null otherwise
    operation : Text; // "store-secret" | "delete-secret" | "agent-orchestrator" | ...
  };

  public type SecretChangeType = {
    #stored : Types.SecretId;
    #deleted : Types.SecretId;
  };

  public type SecretChangeEntry = {
    timestamp : Int;
    changeType : SecretChangeType;
    requester : SecretRequester;
  };

  public type SecretAccessEntry = {
    timestamp : Int;
    secretId : Types.SecretId;
    requester : SecretRequester;
  };

  /// Per-workspace audit state: change log (write events) + access log (read events).
  /// `var` fields allow `purgeAllWorkspaceLogs` to reassign them to filtered copies.
  public type WorkspaceAuditState = {
    var changeLog : List.List<SecretChangeEntry>;
    var accessLog : List.List<SecretAccessEntry>;
  };

  // ============================================
  // Secrets state
  // ============================================

  /// Combined secrets state: encrypted data + audit logs, both keyed by workspaceId.
  public type SecretsState = {
    data : Map.Map<Nat, Map.Map<Types.SecretId, EncryptedSecret>>;
    audit : Map.Map<Nat, WorkspaceAuditState>;
  };

  /// Create the initial (empty) SecretsState.
  public func initState() : SecretsState {
    {
      data = Map.empty<Nat, Map.Map<Types.SecretId, EncryptedSecret>>();
      audit = Map.empty<Nat, WorkspaceAuditState>();
    };
  };

  // ============================================
  // Comparators and helpers
  // ============================================

  /// Comparator for SecretId enum.
  /// Uses the stable string representation so that the BTree ordering is
  /// independent of the variant declaration order — adding or reordering
  /// variants in the future will never silently corrupt stored keys.
  public func compareSecretId(a : Types.SecretId, b : Types.SecretId) : Order.Order {
    Text.compare(secretIdToString(a), secretIdToString(b));
  };

  private func secretIdToString(id : Types.SecretId) : Text {
    switch (id) {
      case (#openRouterApiKey) { "openRouterApiKey" };
      case (#openaiApiKey) { "openaiApiKey" };
      case (#anthropicApiKey) { "anthropicApiKey" };
      case (#anthropicSetupToken) { "anthropicSetupToken" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
      case (#custom(name)) { "custom:" # name };
    };
  };

  /// Whether a *read* (access log) entry should be written for this (workspaceId, secretId).
  /// For workspace 0, high-frequency org credentials (slackBotToken, slackSigningSecret)
  /// are excluded to avoid flooding the access log on every webhook signature check.
  /// All reads on workspace > 0 are always logged.
  /// Change log entries (storeSecret, deleteSecret) are NEVER excluded regardless of this list.
  private func shouldLog(workspaceId : Nat, secretId : Types.SecretId) : Bool {
    if (workspaceId != 0) { return true };
    Array.find<Types.SecretId>(
      Constants.SECRET_AUDIT_EXCLUSIONS,
      func(id) { id == secretId },
    ) == null;
  };

  /// Get (or lazily create) the WorkspaceAuditState for a workspace.
  private func getOrInitWorkspaceAudit(
    audit : Map.Map<Nat, WorkspaceAuditState>,
    workspaceId : Nat,
  ) : WorkspaceAuditState {
    switch (Map.get(audit, Nat.compare, workspaceId)) {
      case (?state) { state };
      case (null) {
        let newState : WorkspaceAuditState = {
          var changeLog = List.empty<SecretChangeEntry>();
          var accessLog = List.empty<SecretAccessEntry>();
        };
        Map.add(audit, Nat.compare, workspaceId, newState);
        newState;
      };
    };
  };

  // ============================================
  // Secret operations
  // ============================================

  /// Get and decrypt a secret for a specific workspace and secret ID.
  /// Logs an access entry when the secret is found (unless excluded by shouldLog).
  public func getSecret(
    state : SecretsState,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    secretId : Types.SecretId,
    requester : SecretRequester,
  ) : ?Text {
    let result = switch (Map.get(state.data, Nat.compare, workspaceId)) {
      case (null) { null };
      case (?workspaceSecrets) {
        switch (Map.get(workspaceSecrets, compareSecretId, secretId)) {
          case (null) { null };
          case (?encryptedBlob) {
            let encryptedBytes = Blob.toArray(encryptedBlob);
            let decryptedBytes = Encryption.decrypt(encryptionKey, encryptedBytes);
            Encryption.bytesToText(decryptedBytes);
          };
        };
      };
    };
    // Log access only when the secret was found and is not excluded
    if (result != null and shouldLog(workspaceId, secretId)) {
      let wsAudit = getOrInitWorkspaceAudit(state.audit, workspaceId);
      List.add(
        wsAudit.accessLog,
        {
          timestamp = Time.now();
          secretId;
          requester;
        },
      );
    };
    result;
  };

  /// Encrypt and store a secret for a workspace.
  /// Always logs a change entry due to its sensitive nature.
  public func storeSecret(
    state : SecretsState,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    secretId : Types.SecretId,
    secret : Text,
    requester : SecretRequester,
  ) : Result.Result<(), Text> {
    let plaintextBytes = Encryption.textToBytes(secret);
    let encryptedBytes = Encryption.encrypt(encryptionKey, plaintextBytes, workspaceId);
    let encryptedBlob = Blob.fromArray(encryptedBytes);

    let workspaceSecrets = switch (Map.get(state.data, Nat.compare, workspaceId)) {
      case (null) { Map.empty<Types.SecretId, EncryptedSecret>() };
      case (?existingMap) { existingMap };
    };
    Map.add(workspaceSecrets, compareSecretId, secretId, encryptedBlob);
    Map.add(state.data, Nat.compare, workspaceId, workspaceSecrets);

    let wsAudit = getOrInitWorkspaceAudit(state.audit, workspaceId);
    List.add(
      wsAudit.changeLog,
      {
        timestamp = Time.now();
        changeType = #stored(secretId);
        requester;
      },
    );

    #ok(());
  };

  /// Get workspace's stored secret identifiers (without decrypting).
  /// Returns the list of SecretId values that have stored secrets.
  public func getWorkspaceSecrets(
    state : SecretsState,
    workspaceId : Nat,
  ) : Result.Result<[Types.SecretId], Text> {
    switch (Map.get(state.data, Nat.compare, workspaceId)) {
      case (null) { #ok([]) };
      case (?workspaceSecrets) { #ok(Iter.toArray(Map.keys(workspaceSecrets))) };
    };
  };

  /// Delete a secret for a specific secret ID in a workspace.
  /// Always logs a change entry due to its sensitive nature.
  public func deleteSecret(
    state : SecretsState,
    workspaceId : Nat,
    secretId : Types.SecretId,
    requester : SecretRequester,
  ) : Result.Result<(), Text> {
    switch (Map.get(state.data, Nat.compare, workspaceId)) {
      case (null) { #err("No secrets found for this workspace.") };
      case (?workspaceSecrets) {
        switch (Map.get(workspaceSecrets, compareSecretId, secretId)) {
          case (null) {
            #err("No secret found for " # secretIdToString(secretId) # ".");
          };
          case (?_) {
            ignore Map.delete(workspaceSecrets, compareSecretId, secretId);
            Map.add(state.data, Nat.compare, workspaceId, workspaceSecrets);
            let wsAudit = getOrInitWorkspaceAudit(state.audit, workspaceId);
            List.add(
              wsAudit.changeLog,
              {
                timestamp = Time.now();
                changeType = #deleted(secretId);
                requester;
              },
            );
            #ok(());
          };
        };
      };
    };
  };

  // ============================================
  // Audit log queries and maintenance
  // ============================================

  /// Purge change and access log entries older than `retentionNs` nanoseconds for all workspaces.
  /// Returns total number of entries purged.
  public func purgeAllWorkspaceLogs(state : SecretsState, retentionNs : Nat) : Nat {
    let cutoff : Int = Time.now() - retentionNs;
    var purged : Nat = 0;
    for (wsAudit in Map.values(state.audit)) {
      var p : Nat = 0;
      let keptChanges = List.filter<SecretChangeEntry>(
        wsAudit.changeLog,
        func(e) { if (e.timestamp >= cutoff) { true } else { p += 1; false } },
      );
      if (p > 0) { wsAudit.changeLog := keptChanges };
      purged += p;
      p := 0;
      let keptAccess = List.filter<SecretAccessEntry>(
        wsAudit.accessLog,
        func(e) { if (e.timestamp >= cutoff) { true } else { p += 1; false } },
      );
      if (p > 0) { wsAudit.accessLog := keptAccess };
      purged += p;
    };
    purged;
  };

  /// Return all change log entries for a workspace since a given timestamp (inclusive).
  public func getChangeLogSince(state : SecretsState, workspaceId : Nat, since : Int) : [SecretChangeEntry] {
    switch (Map.get(state.audit, Nat.compare, workspaceId)) {
      case (null) { [] };
      case (?wsAudit) {
        List.toArray(
          List.filter<SecretChangeEntry>(wsAudit.changeLog, func(e) { e.timestamp >= since })
        );
      };
    };
  };

  /// Return all access log entries for a workspace since a given timestamp (inclusive).
  public func getAccessLogSince(state : SecretsState, workspaceId : Nat, since : Int) : [SecretAccessEntry] {
    switch (Map.get(state.audit, Nat.compare, workspaceId)) {
      case (null) { [] };
      case (?wsAudit) {
        List.toArray(
          List.filter<SecretAccessEntry>(wsAudit.accessLog, func(e) { e.timestamp >= since })
        );
      };
    };
  };

  // ============================================
  // Credential cascade
  // ============================================

  /// Resolve a secret for an agent using the 3-level credential cascade:
  ///
  ///   1. Agent override: check `agent.secretOverrides` for `(targetSecretId, customName)`.
  ///      If found, look up `#custom(customName)` in the agent's workspace.
  ///   2. Workspace standard: look up `targetSecretId` directly in the agent's workspace.
  ///   3. Org fallback: if `workspaceId != 0`, look up `targetSecretId` in workspace 0
  ///      using `orgKey`.
  ///
  /// First non-null result wins.  Access log entries are written via the existing
  /// `getSecret` path at whichever level resolves — consistent with the rest of the model.
  ///
  /// `workspaceKey` must be the derived encryption key for `workspaceId`.
  /// `orgKey` must be the derived encryption key for workspace 0.
  /// When `workspaceId == 0`, `workspaceKey` and `orgKey` are the same and step 3 is skipped.
  public func resolveSecret(
    state : SecretsState,
    agent : AgentModel.AgentRecord,
    workspaceId : Nat,
    targetSecretId : Types.SecretId,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    requester : SecretRequester,
  ) : ?Text {
    // Step 1 — agent-level custom override
    for ((overrideId, customName) in agent.secretOverrides.vals()) {
      if (overrideId == targetSecretId) {
        let result = getSecret(state, workspaceKey, workspaceId, #custom(customName), requester);
        if (result != null) { return result };
      };
    };

    // Step 2 — workspace-level standard key
    let wsResult = getSecret(state, workspaceKey, workspaceId, targetSecretId, requester);
    if (wsResult != null) { return wsResult };

    // Step 3 — org-level fallback (only when agent is not already on workspace 0)
    if (workspaceId != 0) {
      return getSecret(state, orgKey, 0, targetSecretId, requester);
    };

    null;
  };
};
