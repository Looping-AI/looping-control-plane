/// Conversation Model
///
/// Channel-keyed, timeline-structured persistent conversation store.
///
/// Design summary:
///   - Outer key: Slack channelId (Text) → ChannelStore
///   - ChannelStore.timeline : Map<ts, TimelineEntry>   — ordered channel view
///     - TimelineEntry = #post ConversationMessage       — standalone message (99% case)
///                     | #thread ThreadGroup             — root + ≥1 replies
///   - ChannelStore.replyIndex : Map<ts, rootTs>        — reply-only reverse lookup
///   - ThreadGroup.messages : Map<ts, ConversationMessage> — O(log M) msg access
///
/// All maps use Text.compare on Slack ts strings, which sort
/// lexicographically == chronologically (10-digit seconds prefix).
///
/// Top-level messages (no replies) are stored as a flat #post — no wrapper map
/// allocation. When the first reply arrives, #post is promoted to #thread in-place.
/// The replyIndex only contains reply ts values (never the root/post ts), keeping
/// it sparse in the typical no-thread scenario.
///
/// LLM tool messages (tool_call / tool_response) are NOT persisted here;
/// they are ephemeral and exist only in-memory during a single service invocation.
///
/// TODO: when Sessions are implemented (Phase 1.7), associate in-flight tool
/// call/response history with a SessionRecord rather than keeping it purely
/// ephemeral. Sessions will be nextId-based and optionally linkable to a
/// slackTs, a batch of ts values, or future concepts like Tasks and Strategies.

import Map "mo:core/Map";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";

module {

  // ============================================
  // Types
  // ============================================

  /// A single message stored in the conversation.
  ///
  /// - `ts`: Slack-assigned timestamp; format "UNIX_SECONDS.MICROSECONDS"
  ///   (e.g. "1740000000.123456"). Unique per channel; serves as the
  ///   deduplication key and as the retention age indicator.
  /// - `userAuthContext`: null for bot/agent messages; set for user messages.
  ///   At LLM context-build time: null → #assistant role, non-null → #user role.
  /// - `text`: current message text; replaced in-place on message_changed events.
  public type ConversationMessage = {
    ts : Text;
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;
    text : Text;
  };

  /// A thread that has a root message and at least one reply.
  ///
  /// - `rootTs`: ts of the thread root message.
  /// - `messages`: all messages in the thread (root + replies), keyed by ts,
  ///   sorted chronologically via Text.compare.
  public type ThreadGroup = {
    rootTs : Text;
    messages : Map.Map<Text, ConversationMessage>;
  };

  /// A single entry in the channel timeline.
  ///
  /// - `#post`: a standalone top-level message with no replies (99% case).
  ///   No inner map allocation — just the message itself.
  /// - `#thread`: a root message that has accumulated at least one reply.
  ///   Promoted in-place from #post when the first reply arrives.
  public type TimelineEntry = {
    #post : ConversationMessage;
    #thread : ThreadGroup;
  };

  /// Per-channel index structures.
  ///
  /// - `timeline`:      Map<ts, TimelineEntry>         — full ordered channel view; O(log N)
  /// - `replyIndex`:    Map<ts, rootTs>                — reply-only reverse lookup; O(log R)
  ///   Root/post ts values are the key in `timeline` so they never need indexing.
  public type ChannelStore = {
    timeline : Map.Map<Text, TimelineEntry>;
    replyIndex : Map.Map<Text, Text>;
  };

  /// The conversation store: one ChannelStore per channel.
  public type ConversationStore = Map.Map<Text, ChannelStore>;

  // ============================================
  // Constructor
  // ============================================

  /// Return a new, empty ConversationStore.
  public func empty() : ConversationStore {
    Map.empty<Text, ChannelStore>();
  };

  // ============================================
  // Internal helpers
  // ============================================

  private func getOrCreateChannelStore(
    store : ConversationStore,
    channelId : Text,
  ) : ChannelStore {
    switch (Map.get(store, Text.compare, channelId)) {
      case (?ch) { ch };
      case (null) {
        let ch : ChannelStore = {
          timeline = Map.empty<Text, TimelineEntry>();
          replyIndex = Map.empty<Text, Text>();
        };
        Map.add(store, Text.compare, channelId, ch);
        ch;
      };
    };
  };

  /// Parse the integer-second prefix of a Slack ts string ("SECONDS.MICROSECONDS").
  /// Returns null if the string cannot be parsed.
  private func tsSeconds(ts : Text) : ?Nat {
    switch (Text.split(ts, #char '.').next()) {
      case (null) { null };
      case (?secStr) { Nat.fromText(secStr) };
    };
  };

  // ============================================
  // addMessage
  // ============================================

  /// Persist a message into the conversation store.
  ///
  /// - `threadTs = null` → top-level post: store as #post (no replyIndex entry).
  /// - `threadTs = ?rootTs` → reply:
  ///     - Existing #post at rootTs → promote to #thread (first-reply upgrade).
  ///     - Existing #thread at rootTs → append to its messages map.
  ///     - No entry at rootTs → create sparse #thread (reply arrived before root).
  ///   A replyIndex entry (msg.ts → rootTs) is added for every reply.
  public func addMessage(
    store : ConversationStore,
    channelId : Text,
    msg : ConversationMessage,
    threadTs : ?Text,
  ) {
    let ch = getOrCreateChannelStore(store, channelId);
    switch (threadTs) {
      case (null) {
        // Top-level post — flat storage, no replyIndex entry needed.
        // If a sparse #thread already exists at this ts (reply arrived before root),
        // merge the root message into the existing thread instead of overwriting it.
        switch (Map.get(ch.timeline, Text.compare, msg.ts)) {
          case (?#thread thread) {
            // Root arrived after replies — attach root to existing thread.
            Map.add(thread.messages, Text.compare, msg.ts, msg);
            // Ensure the timeline continues to point at the thread entry.
            Map.add(ch.timeline, Text.compare, msg.ts, #thread thread);
          };
          case (_) {
            // No existing thread — store as a simple post.
            Map.add(ch.timeline, Text.compare, msg.ts, #post msg);
          };
        };
      };
      case (?rootTs) {
        // Reply — always register in replyIndex.
        Map.add(ch.replyIndex, Text.compare, msg.ts, rootTs);
        switch (Map.get(ch.timeline, Text.compare, rootTs)) {
          case (?#thread thread) {
            // Already a thread — simply append the reply.
            Map.add(thread.messages, Text.compare, msg.ts, msg);
          };
          case (?#post rootMsg) {
            // First reply: promote #post → #thread.
            let msgs = Map.empty<Text, ConversationMessage>();
            Map.add(msgs, Text.compare, rootMsg.ts, rootMsg);
            Map.add(msgs, Text.compare, msg.ts, msg);
            Map.add(
              ch.timeline,
              Text.compare,
              rootTs,
              #thread { rootTs; messages = msgs },
            );
          };
          case (null) {
            // Reply arrived before root — create sparse #thread.
            let msgs = Map.empty<Text, ConversationMessage>();
            Map.add(msgs, Text.compare, msg.ts, msg);
            Map.add(
              ch.timeline,
              Text.compare,
              rootTs,
              #thread { rootTs; messages = msgs },
            );
          };
        };
      };
    };
  };

  // ============================================
  // Round context
  // ============================================

  // ============================================
  // getMessage
  // ============================================

  /// Return the `ConversationMessage` for (channelId, ts), or null if not found.
  ///
  /// Lookup strategy (O(log N + log M)):
  ///   1. Check `replyIndex` — if `ts` is a reply, get the rootTs, then find the
  ///      message in the `#thread`’s messages map.
  ///   2. Otherwise check `timeline` directly — `ts` is itself a root/post ts.
  ///
  /// Used by the bot-message path in MessageHandler to resolve the parent message
  /// and derive the new `roundCount`.
  public func getMessage(
    store : ConversationStore,
    channelId : Text,
    ts : Text,
  ) : ?ConversationMessage {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { null };
      case (?ch) {
        // Try reply lookup first (fast for non-root ts values).
        switch (Map.get(ch.replyIndex, Text.compare, ts)) {
          case (?rootTs) {
            // ts is a reply — find the message in the parent thread.
            switch (Map.get(ch.timeline, Text.compare, rootTs)) {
              case (?#thread thread) {
                Map.get(thread.messages, Text.compare, ts);
              };
              case _ { null };
            };
          };
          case (null) {
            // ts is not a reply — check if it is a root/post ts in the timeline.
            switch (Map.get(ch.timeline, Text.compare, ts)) {
              case (?#post msg) { ?msg };
              case (?#thread thread) {
                // Root of a thread — retrieve the root message from messages map.
                Map.get(thread.messages, Text.compare, ts);
              };
              case (null) { null };
            };
          };
        };
      };
    };
  };

  // ============================================
  // getEntry
  // ============================================

  /// Return the TimelineEntry for (channelId, rootTs), or null if not found.
  /// O(log N) — direct timeline lookup.
  public func getEntry(
    store : ConversationStore,
    channelId : Text,
    rootTs : Text,
  ) : ?TimelineEntry {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { null };
      case (?ch) { Map.get(ch.timeline, Text.compare, rootTs) };
    };
  };

  // ============================================
  // getRecentEntries
  // ============================================

  /// Return a lightweight summary of the last `limit` entries in the channel timeline.
  /// Each summary carries `ts` (the root/post ts) and a `hasReplies` flag.
  /// Entries are ordered chronologically (Text.compare on ts = lexicographic = time order).
  public func getRecentEntries(
    store : ConversationStore,
    channelId : Text,
    limit : Nat,
  ) : [{ ts : Text; hasReplies : Bool }] {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { [] };
      case (?ch) {
        let arr = Map.toArray(ch.timeline); // [(ts, TimelineEntry)], sorted by key
        let total = arr.size();
        let startIndex = if (total > limit) Nat.sub(total, limit) else 0;
        let count = Nat.sub(total, startIndex);
        Array.tabulate<{ ts : Text; hasReplies : Bool }>(
          count,
          func(i) {
            let (ts, entry) = arr[startIndex + i];
            {
              ts;
              hasReplies = switch (entry) {
                case (#post _) { false };
                case (#thread _) { true };
              };
            };
          },
        );
      };
    };
  };

  // ============================================
  // updateMessageText
  // ============================================

  /// Replace the `text` of the message identified by (channelId, rootTs, ts).
  /// `rootTs` is derived from the message_changed event: threadTs ?? messageTs.
  /// O(log N + log M) — no list traversal, no allocation for non-matching entries.
  /// Returns true if the message was found and updated.
  public func updateMessageText(
    store : ConversationStore,
    channelId : Text,
    rootTs : Text,
    ts : Text,
    newText : Text,
  ) : Bool {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { false };
      case (?ch) {
        switch (Map.get(ch.timeline, Text.compare, rootTs)) {
          case (null) { false };
          case (?#post msg) {
            if (msg.ts != ts) { return false };
            Map.add(
              ch.timeline,
              Text.compare,
              rootTs,
              #post {
                ts = msg.ts;
                userAuthContext = msg.userAuthContext;
                text = newText;
              },
            );
            true;
          };
          case (?#thread thread) {
            switch (Map.get(thread.messages, Text.compare, ts)) {
              case (null) { false };
              case (?msg) {
                Map.add(
                  thread.messages,
                  Text.compare,
                  ts,
                  {
                    ts = msg.ts;
                    userAuthContext = msg.userAuthContext;
                    text = newText;
                  },
                );
                true;
              };
            };
          };
        };
      };
    };
  };

  // ============================================
  // updateMessageContext
  // ============================================

  /// Replace the `userAuthContext` of the message identified by (channelId, rootTs, ts).
  /// `rootTs` is `threadTs ?? messageTs` — the same value passed to `addMessage`.
  /// O(log N + log M) — no list traversal.
  /// Returns true if the message was found and updated.
  public func updateMessageContext(
    store : ConversationStore,
    channelId : Text,
    rootTs : Text,
    ts : Text,
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext,
  ) : Bool {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { false };
      case (?ch) {
        switch (Map.get(ch.timeline, Text.compare, rootTs)) {
          case (null) { false };
          case (?#post msg) {
            if (msg.ts != ts) { return false };
            Map.add(
              ch.timeline,
              Text.compare,
              rootTs,
              #post {
                ts = msg.ts;
                userAuthContext;
                text = msg.text;
              },
            );
            true;
          };
          case (?#thread thread) {
            switch (Map.get(thread.messages, Text.compare, ts)) {
              case (null) { false };
              case (?msg) {
                Map.add(
                  thread.messages,
                  Text.compare,
                  ts,
                  {
                    ts = msg.ts;
                    userAuthContext;
                    text = msg.text;
                  },
                );
                true;
              };
            };
          };
        };
      };
    };
  };

  // ============================================
  // deleteMessage
  // ============================================

  /// Remove the message with `ts` from (channelId, rootTs).
  /// - For a #post: removes the entry from the timeline.
  /// - For a #thread reply: removes the message; also removes its replyIndex entry.
  ///   If the thread becomes empty, the timeline entry is dropped too.
  /// O(log N + log M) — all map operations.
  /// Returns true if the message was found and removed.
  public func deleteMessage(
    store : ConversationStore,
    channelId : Text,
    rootTs : Text,
    ts : Text,
  ) : Bool {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { false };
      case (?ch) {
        switch (Map.get(ch.timeline, Text.compare, rootTs)) {
          case (null) { false };
          case (?#post msg) {
            if (msg.ts != ts) { return false };
            Map.remove(ch.timeline, Text.compare, rootTs);
            true;
          };
          case (?#thread thread) {
            if (not Map.containsKey(thread.messages, Text.compare, ts)) {
              return false;
            };
            Map.remove(thread.messages, Text.compare, ts);
            // Replies (ts ≠ rootTs) have a replyIndex entry; clean it up.
            if (ts != rootTs) {
              Map.remove(ch.replyIndex, Text.compare, ts);
            };
            // Drop the thread itself if it is now empty.
            if (Map.isEmpty(thread.messages)) {
              Map.remove(ch.timeline, Text.compare, rootTs);
            };
            true;
          };
        };
      };
    };
  };

  // ============================================
  // findAndDeleteMessage
  // ============================================

  /// Find and remove the message with `ts` without knowing its rootTs up-front.
  ///
  /// Strategy:
  ///   1. Check replyIndex — if found, ts is a reply → deleteMessage(rootTs, ts).
  ///   2. Otherwise check timeline directly — ts is itself a root/post ts.
  ///
  /// O(log R) for replies; O(log N) for root/post messages.
  /// Returns true if the message was found and removed.
  public func findAndDeleteMessage(
    store : ConversationStore,
    channelId : Text,
    ts : Text,
  ) : Bool {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) { false };
      case (?ch) {
        switch (Map.get(ch.replyIndex, Text.compare, ts)) {
          case (?rootTs) {
            // ts is a reply — delegate with known rootTs.
            deleteMessage(store, channelId, rootTs, ts);
          };
          case (null) {
            // ts is not a reply — check if it is a root/post ts in the timeline.
            switch (Map.get(ch.timeline, Text.compare, ts)) {
              case (null) { false }; // never stored or already pruned
              case (?_) {
                deleteMessage(store, channelId, ts, ts);
              };
            };
          };
        };
      };
    };
  };

  // ============================================
  // Retention / pruning
  // ============================================

  /// Drop entries from `channelId` where ALL messages are older than `cutoffSecs`.
  /// Old-thread grace rule: if any message in a #thread has ts >= cutoffSecs
  /// (i.e. a recent reply to an old thread), the entire thread is kept.
  /// Removes pruned reply ts values from replyIndex as well.
  /// O(N × M) — unavoidable full scan; runs at most once per week from the timer.
  public func pruneChannel(
    store : ConversationStore,
    channelId : Text,
    cutoffSecs : Nat,
  ) {
    switch (Map.get(store, Text.compare, channelId)) {
      case (null) {};
      case (?ch) {
        // Collect root ts values to drop (can't mutate while iterating).
        // Use List instead of Array to avoid O(n²) cost from repeated Array.concat.
        var toRemove : List.List<Text> = List.empty<Text>();
        for ((rootTs, entry) in Map.entries(ch.timeline)) {
          switch (entry) {
            case (#post msg) {
              switch (tsSeconds(msg.ts)) {
                case (?secs) {
                  if (secs < cutoffSecs) {
                    List.add(toRemove, rootTs);
                  };
                };
                case (null) { /* unparseable ts — keep conservatively */ };
              };
            };
            case (#thread thread) {
              var hasRecentMessage = false;
              for ((_, msg) in Map.entries(thread.messages)) {
                switch (tsSeconds(msg.ts)) {
                  case (?secs) {
                    if (secs >= cutoffSecs) { hasRecentMessage := true };
                  };
                  case (null) {
                    // Unparseable ts → keep conservatively.
                    hasRecentMessage := true;
                  };
                };
              };
              if (not hasRecentMessage) {
                List.add(toRemove, rootTs);
              };
            };
          };
        };
        // Remove stale entries and their replyIndex entries.
        // Convert List to array for iteration (post-collection).
        for (rootTs in List.toArray(toRemove).vals()) {
          switch (Map.get(ch.timeline, Text.compare, rootTs)) {
            case (?#thread thread) {
              // Clean up reply ts values from replyIndex.
              for ((ts, _) in Map.entries(thread.messages)) {
                if (ts != rootTs) {
                  Map.remove(ch.replyIndex, Text.compare, ts);
                };
              };
            };
            case (_) {};
          };
          Map.remove(ch.timeline, Text.compare, rootTs);
        };
      };
    };
  };

  /// Run pruneChannel for every channel in the store.
  /// Invoked by the Sunday cleanup timer to enforce 1-month retention.
  public func pruneAll(store : ConversationStore, cutoffSecs : Nat) {
    for ((channelId, _) in Map.entries(store)) {
      pruneChannel(store, channelId, cutoffSecs);
    };
  };
};
