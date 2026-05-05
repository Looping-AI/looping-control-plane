/// TurnContextService
///
/// Centralises the per-turn execution context resolution that was previously
/// duplicated across `resumeAdminTurn` (main.mo), `dispatchApproved`
/// (approval-dispatch-service.mo), and `agent-orchestrator.orchestrate`.
///
/// Resolution is split into two halves because Motoko requires the result of
/// an `async` function to be **shareable** — it cannot carry mutable records
/// (`var` fields), unshareable containers (`mo:core/Set`, `mo:core/Map`), or
/// closures across an async boundary.
///
///   • `asyncResolve(...) : async Result<TurnContext, ResolveError>`
///       Performs all the work that requires `await`: org + workspace key
///       derivation (Threshold Schnorr) and any decrypt-time secret access.
///       Returns shareable primitives only.
///
///   • `syncResolve(deps, ctx, turnId) : TurnHandles`
///       Re-attaches the non-shareable handles that could not survive the
///       async boundary: the mutable `turn` and `agent` records and the
///       `resolveSlackBotToken` closure. These lookups are guaranteed to
///       succeed because `asyncResolve` already validated existence and the
///       IC is single-threaded between awaits — a missing record here would
///       be state corruption, so we trap via `Runtime.unreachable()`.
///
/// Typical call site:
///
///   let ctx = switch (await TurnContextService.asyncResolve(...)) {
///     case (#err(e)) { ...handle... };
///     case (#ok(c)) { c };
///   };
///   let syncCtx = TurnContextService.syncResolve(deps, ctx, turnId);
///   // use ctx.apiKey/orgKey/workspaceKey/sourceRef + syncCtx.turn/syncCtx.agent/syncCtx.resolveSlackBotToken
///
/// `keyCache` is intentionally passed at call time rather than captured in
/// `Deps`, because it is a `transient var` in main.mo and may be swapped by
/// the key-rotation timer between construction and the first call.

import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import AgentModel "../models/agent-model";
import KeyDerivationService "key-derivation-service";
import SecretModel "../models/secret-model";
import SessionModel "../models/session-model";

module {

  // ── Types ──────────────────────────────────────────────────────────────────

  public type Deps = {
    sessionStores : SessionModel.SessionStores;
    agentRegistry : AgentModel.AgentRegistryState;
    secrets : SecretModel.SecretsState;
  };

  /// Shareable half of the resolved turn context. Carries everything that can
  /// safely cross an async boundary; non-shareable handles are obtained via
  /// `syncResolve`.
  public type TurnContext = {
    agentId : Nat;
    orgKey : [Nat8];
    workspaceKey : [Nat8];
    apiKey : Text;
    /// Copied from turn.sourceRef — shareable, avoids a separate turn lookup
    /// just to read coordinates.
    sourceRef : ?SessionModel.SourceRef;
    /// Channel coordinates extracted from sourceRef for convenience.
    channelId : Text;
    ts : Text;
    threadTs : ?Text;
  };

  /// Non-shareable handles re-attached after the async boundary.
  public type TurnHandles = {
    turn : SessionModel.AgentTurnRecord;
    agent : AgentModel.AgentRecord;
    /// Slack bot-token resolver — pass an operation label for audit logging.
    resolveSlackBotToken : Text -> ?Text;
  };

  /// Resolution failure details.
  /// `stage` is a stable identifier callers can use to label a ProcessingStep.
  public type ResolveError = {
    stage : Text;
    message : Text;
  };

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Resolve all per-turn execution context that requires `await`.
  /// Returns shareable primitives only — call `syncResolve` afterwards to
  /// rehydrate the mutable `turn`/`agent` records and bot-token closure.
  ///
  /// `slackUserId` is forwarded to the secret requester for audit logging;
  /// pass `null` when the resolution is triggered by an async system path
  /// (e.g. engine-completion resume) where no human user is directly involved.
  public func asyncResolve(
    deps : Deps,
    keyCache : KeyDerivationService.KeyCache,
    turnId : Text,
    slackUserId : ?Text,
  ) : async { #ok : TurnContext; #err : ResolveError } {

    // 1. Turn lookup
    let turn = switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
      case (?t) { t };
      case null {
        return #err({
          stage = "turn_lookup";
          message = "Turn not found: " # turnId;
        });
      };
    };

    // 2. Agent lookup
    let agent = switch (AgentModel.lookupById(deps.agentRegistry, turn.agentId)) {
      case (?a) { a };
      case null {
        return #err({
          stage = "agent_lookup";
          message = "Agent not found: " # Nat.toText(turn.agentId);
        });
      };
    };

    // 3. Key derivation (cached — second call for the same workspace is free)
    let orgKey = await KeyDerivationService.getOrDeriveKey(keyCache, 0);
    let workspaceKey = await KeyDerivationService.getOrDeriveKey(keyCache, agent.ownedBy);

    // 4. API key
    let apiKey = switch (
      SecretModel.resolveSecret(
        deps.secrets,
        agent,
        agent.ownedBy,
        #openRouterApiKey,
        workspaceKey,
        orgKey,
        { slackUserId; agentId = ?agent.id; operation = "turn-context" },
      )
    ) {
      case (?key) { key };
      case null {
        return #err({
          stage = "api_key";
          message = "No OpenRouter API key configured for agent " # Nat.toText(agent.id);
        });
      };
    };

    // 5. Channel coordinates (copied from sourceRef for caller convenience)
    let (channelId, ts, threadTs) : (Text, Text, ?Text) = switch (turn.sourceRef) {
      case (?#slack({ channelId; ts; threadTs })) { (channelId, ts, threadTs) };
      case (_) { ("", "", null) };
    };

    #ok({
      agentId = turn.agentId;
      orgKey;
      workspaceKey;
      apiKey;
      sourceRef = turn.sourceRef;
      channelId;
      ts;
      threadTs;
    });
  };

  /// Re-attach the non-shareable handles (mutable `turn`/`agent` records and
  /// the bot-token resolver closure) after the async boundary.
  ///
  /// Must only be called with a `ctx` produced by a successful `asyncResolve`
  /// for the same `turnId`. Existence has already been validated there and
  /// the IC is single-threaded between awaits, so any missing record here
  /// would indicate state corruption; we trap via `Runtime.unreachable()`.
  public func syncResolve(
    deps : Deps,
    ctx : TurnContext,
    turnId : Text,
  ) : TurnHandles {
    let turn = switch (SessionModel.findTurn(deps.sessionStores, turnId)) {
      case (?t) { t };
      case null { Runtime.unreachable() };
    };
    let agent = switch (AgentModel.lookupById(deps.agentRegistry, ctx.agentId)) {
      case (?a) { a };
      case null { Runtime.unreachable() };
    };
    let resolveSlackBotToken : Text -> ?Text = func(operation : Text) : ?Text {
      SecretModel.resolvePlatformSecret(
        deps.secrets,
        ctx.orgKey,
        null,
        #slackBotToken,
        { slackUserId = null; agentId = null; operation },
      );
    };
    { turn; agent; resolveSlackBotToken };
  };
};
