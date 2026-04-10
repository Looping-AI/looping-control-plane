/// Context Assembler
///
/// Shared module that assembles LLM input context from multiple sources:
///   1. Session memory — compaction summaries (cold → warm → hot)
///   2. Turn digests — recent completed turns with tool/response traces
///   3. Channel history — last N root messages from the channel timeline
///   4. Thread history — last N messages from the current thread (if any)
///
/// Session context is serialized as structured JSON with IDs in `#developer`
/// messages. Channel/thread messages use natural `#user`/`#assistant` roles
/// to preserve conversation semantics for the model.
///
/// Turn digests are budget-based: iterate newest → oldest until consuming
/// half of `summaryTokenBudget`. Token estimation via chars/4.

import Array "mo:core/Array";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Json "mo:json";
import { str; obj; arr } "mo:json";
import ChannelHistoryModel "../models/channel-history-model";
import SessionModel "../models/session-model";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";

module {

  // ─── Constants ─────────────────────────────────────────────────────────────

  /// Maximum number of root messages to include from the channel timeline.
  let MAX_CHANNEL_MESSAGES : Nat = 10;

  /// Maximum number of messages to include from the current thread.
  let MAX_THREAD_MESSAGES : Nat = 10;

  // ─── Types ─────────────────────────────────────────────────────────────────

  public type AssembledContext = {
    messages : [OpenRouterWrapper.ResponseInputMessage];
    stats : ContextStats;
  };

  public type ContextStats = {
    summaryTokens : Nat;
    rawTurnsIncluded : Nat;
    channelSnippets : Nat;
  };

  // ─── Token estimation ──────────────────────────────────────────────────────

  /// Approximate token count from character length (chars / 4, rounded up).
  func estimateTokens(text : Text) : Nat {
    (Text.size(text) + 3) / 4;
  };

  // ─── Session memory ────────────────────────────────────────────────────────

  /// Build JSON entries from non-empty compaction summaries (cold → warm → hot).
  func buildSessionMemoryEntries(
    session : SessionModel.AgentSessionRecord
  ) : [Json.Json] {
    let entries = List.empty<Json.Json>();
    switch (session.compaction.coldSummary) {
      case (?cold) {
        if (cold != "") {
          List.add(
            entries,
            obj([
              ("id", str("session-memory-cold")),
              ("type", str("session_memory")),
              ("layer", str("cold")),
              ("value", str(cold)),
            ]),
          );
        };
      };
      case (null) {};
    };
    switch (session.compaction.warmSummary) {
      case (?warm) {
        if (warm != "") {
          List.add(
            entries,
            obj([
              ("id", str("session-memory-warm")),
              ("type", str("session_memory")),
              ("layer", str("warm")),
              ("value", str(warm)),
            ]),
          );
        };
      };
      case (null) {};
    };
    if (session.compaction.hotSummary != "") {
      List.add(
        entries,
        obj([
          ("id", str("session-memory-hot")),
          ("type", str("session_memory")),
          ("layer", str("hot")),
          ("value", str(session.compaction.hotSummary)),
        ]),
      );
    };
    List.toArray(entries);
  };

  // ─── Turn digests ──────────────────────────────────────────────────────────

  /// Status variant to text for JSON serialization.
  func statusToText(status : SessionModel.TurnStatus) : Text {
    switch (status) {
      case (#running) { "running" };
      case (#succeeded) { "succeeded" };
      case (#failed) { "failed" };
    };
  };

  /// Build a JSON entry for a single turn from its traces.
  /// Reads pre-computed `truncatedContent`, `truncatedThinking`, and
  /// `truncatedOutput` fields written at trace time — no truncation here.
  func buildTurnDigestEntry(
    turn : SessionModel.AgentTurnRecord,
    stores : SessionModel.SessionStores,
  ) : Json.Json {
    let tools = List.empty<Json.Json>();
    var response : Text = "";

    switch (SessionModel.getTraces(stores, turn.turnId)) {
      case (null) {};
      case (?traceList) {
        for (trace in List.values(traceList)) {
          switch (trace.detail) {
            case (#llmCall({ truncatedContent; truncatedThinking; toolRequests = _; model = _; durationMs = _; finishReason = _; cost = _; content = _; thinking = _ })) {
              switch (truncatedContent) {
                case (?c) { response := c };
                case (null) {};
              };
              switch (truncatedThinking) {
                case (?t) {
                  if (response == "") {
                    response := "[thinking] " # t;
                  };
                };
                case (null) {};
              };
            };
            case (#toolCall({ name; truncatedOutput; input = _; output = _; success = _; durationMs = _ })) {
              switch (truncatedOutput) {
                case (?o) { List.add(tools, str(name # ": " # o)) };
                case (null) { List.add(tools, str(name)) };
              };
            };
            case _ {};
          };
        };
      };
    };

    obj([
      ("id", str("turn-" # turn.turnId)),
      ("type", str("turn_activity")),
      ("status", str(statusToText(turn.status))),
      ("tools", arr(List.toArray(tools))),
      ("response", str(response)),
    ]);
  };

  /// Build JSON entries for recent completed turns, budget-limited.
  /// Iterates newest → oldest, respecting lastCompactedTurnId and excluding
  /// currentTurnId. Stops when estimated tokens reach half of summaryTokenBudget.
  func buildTurnDigestEntries(
    stores : SessionModel.SessionStores,
    agentId : Nat,
    currentTurnId : Text,
    session : SessionModel.AgentSessionRecord,
  ) : ([Json.Json], Nat) {
    let budget = session.policy.summaryTokenBudget / 2;
    var usedTokens : Nat = 0;

    let turnMap = switch (SessionModel.getTurnsByAgent(stores, agentId)) {
      case (null) { return ([], 0) };
      case (?m) { m };
    };

    let turnsArr = Map.toArray(turnMap); // [(turnNumber, AgentTurnRecord)], sorted by key (chronological)
    // Collect in reverse order (newest first), then reverse for chronological output
    let collected = List.empty<Json.Json>();
    var idx : Int = turnsArr.size() - 1;

    label scanLoop while (idx >= 0) {
      let (_, turn) = turnsArr[Int.abs(idx)];
      idx -= 1;

      // Skip the current in-progress turn
      if (turn.turnId == currentTurnId) { continue scanLoop };

      // Skip running turns (incomplete)
      if (turn.status == #running) { continue scanLoop };

      // Respect compaction boundary
      switch (session.compaction.lastCompactedTurnId) {
        case (?compactedId) {
          if (turn.turnId == compactedId) { break scanLoop };
        };
        case (null) {};
      };

      let entry = buildTurnDigestEntry(turn, stores);
      let entryText = Json.stringify(entry, null);
      let entryTokens = estimateTokens(entryText);

      if (usedTokens + entryTokens > budget and List.size(collected) > 0) {
        break scanLoop;
      };

      List.add(collected, entry);
      usedTokens += entryTokens;
    };

    // Reverse to restore chronological order (oldest first)
    let result = List.toArray(collected);
    let size = result.size();
    let reversed = Array.tabulate<Json.Json>(
      size,
      func(i) { result[Nat.sub(size - 1, i)] },
    );
    (reversed, usedTokens);
  };

  // ─── Channel history ───────────────────────────────────────────────────────

  /// Map a ChannelMessage to an LLM role.
  func messageRole(msg : ChannelHistoryModel.ChannelMessage) : OpenRouterWrapper.ResponseInputRole {
    switch (msg.userAuthContext) {
      case (null) { #assistant };
      case (?_) { #user };
    };
  };

  /// Build LLM messages from the last N root messages in the channel timeline.
  func buildChannelMessages(
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
  ) : [OpenRouterWrapper.ResponseInputMessage] {
    let rootMsgs = ChannelHistoryModel.getRecentRootMessages(channelHistory, channelId, MAX_CHANNEL_MESSAGES);
    Array.map<ChannelHistoryModel.ChannelMessage, OpenRouterWrapper.ResponseInputMessage>(
      rootMsgs,
      func(msg) {
        { role = messageRole(msg); content = msg.text };
      },
    );
  };

  /// Build LLM messages from the last N messages in a specific thread.
  /// Returns empty if threadTs is null, the entry is not found, or is a #post.
  func buildThreadMessages(
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
  ) : [OpenRouterWrapper.ResponseInputMessage] {
    let rootTs = switch (threadTs) {
      case (null) { return [] };
      case (?ts) { ts };
    };
    let msgs = ChannelHistoryModel.getRecentThreadMessages(channelHistory, channelId, rootTs, MAX_THREAD_MESSAGES);
    Array.map<ChannelHistoryModel.ChannelMessage, OpenRouterWrapper.ResponseInputMessage>(
      msgs,
      func(msg) { { role = messageRole(msg); content = msg.text } },
    );
  };

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Assemble the full LLM context from session memory, turn digests,
  /// channel history, and thread history.
  ///
  /// Returns an `AssembledContext` with the ordered message array and stats.
  /// Also records a `#contextAssembled` trace entry on `currentTurnId`.
  public func assemble(
    sessionStores : SessionModel.SessionStores,
    agentId : Nat,
    currentTurnId : Text,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
  ) : AssembledContext {
    let session = SessionModel.getOrCreateSession(sessionStores, agentId);
    let allMessages = List.empty<OpenRouterWrapper.ResponseInputMessage>();

    // ── 1. Session context (developer message with structured JSON) ──────────
    let memoryEntries = buildSessionMemoryEntries(session);
    let (turnEntries, _turnTokens) = buildTurnDigestEntries(sessionStores, agentId, currentTurnId, session);
    let sessionJsonEntries = Array.concat(memoryEntries, turnEntries);

    if (sessionJsonEntries.size() > 0) {
      let jsonText = Json.stringify(arr(sessionJsonEntries), null);
      List.add(allMessages, { role = #developer; content = jsonText });
    };

    // ── 2. Channel history (user/assistant messages with separator) ──────────
    let channelMsgs = buildChannelMessages(channelHistory, channelId);

    if (channelMsgs.size() > 0) {
      let separator = Json.stringify(
        obj([
          ("id", str("channel-context")),
          ("type", str("separator")),
          ("value", str("Recent messages from this channel:")),
        ]),
        null,
      );
      List.add(allMessages, { role = #developer; content = separator });
      for (msg in channelMsgs.vals()) {
        List.add(allMessages, msg);
      };
    };

    // ── 3. Thread history (user/assistant messages with separator) ────────────
    let threadMsgs = buildThreadMessages(channelHistory, channelId, threadTs);

    if (threadMsgs.size() > 0) {
      let separator = Json.stringify(
        obj([
          ("id", str("thread-context")),
          ("type", str("separator")),
          ("value", str("Current thread conversation:")),
        ]),
        null,
      );
      List.add(allMessages, { role = #developer; content = separator });
      for (msg in threadMsgs.vals()) {
        List.add(allMessages, msg);
      };
    };

    // ── 4. Record trace ──────────────────────────────────────────────────────
    let stats : ContextStats = {
      summaryTokens = estimateTokens(
        switch (sessionJsonEntries.size()) {
          case (0) { "" };
          case (_) { Json.stringify(arr(sessionJsonEntries), null) };
        }
      );
      rawTurnsIncluded = turnEntries.size();
      channelSnippets = channelMsgs.size() + threadMsgs.size();
    };

    SessionModel.appendTrace(
      sessionStores,
      currentTurnId,
      #contextAssembled({
        summaryTokens = stats.summaryTokens;
        rawTurnsIncluded = stats.rawTurnsIncluded;
        channelSnippets = stats.channelSnippets;
      }),
    );

    {
      messages = List.toArray(allMessages);
      stats;
    };
  };
};
