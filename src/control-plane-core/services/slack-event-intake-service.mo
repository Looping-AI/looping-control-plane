/// Slack Event Intake Service
/// Encapsulates the normalize-then-enqueue pipeline that sits between the raw
/// Slack webhook body and the event store. Decoupled from HTTP concerns so it
/// can be unit-tested in isolation via the test canister.
///
/// The caller (main.mo) is responsible for:
///   - Signature verification and key derivation (infrastructure)
///   - Timer scheduling after a successful enqueue (infrastructure)
///
/// This module is purely synchronous (no async) and has no actor state.

import SlackAdapter "../events/slack-adapter";
import EventStoreModel "../models/event-store-model";
import Logger "../utilities/logger";

module {

  /// Result of processing one Slack webhook body through the intake pipeline.
  public type IntakeResult = {
    /// Event was normalized and successfully enqueued. Carries the eventId.
    #enqueued : Text;
    /// Event was normalized but the store already holds the same eventId (dedup).
    #duplicate;
    /// Event was recognized as an event_callback but normalized to a skip
    /// (e.g. bot_message subtype, own-bot without metadata). Carries the reason.
    #skipped : Text;
    /// The envelope was valid JSON but not an event_callback (e.g. url_verification,
    /// app_rate_limited). Caller handles these envelope types itself.
    #notEventCallback;
    /// JSON parsing or envelope validation failed. Carries the error message.
    #parseError : Text;
  };

  /// Process a raw Slack webhook body: parse -> normalize -> enqueue.
  ///
  /// Only handles #event_callback envelopes. All other envelope types — including
  /// url_verification and app_rate_limited — return #notEventCallback so the
  /// caller can handle them directly.
  public func processEventBody(
    eventStore : EventStoreModel.EventStoreState,
    bodyText : Text,
  ) : IntakeResult {
    let envelope = switch (SlackAdapter.parseEnvelope(bodyText)) {
      case (#err(e)) { return #parseError(e) };
      case (#ok(env)) { env };
    };

    let callback = switch (envelope) {
      case (#event_callback(cb)) { cb };
      case _ { return #notEventCallback };
    };

    switch (SlackAdapter.normalizeEvent(callback)) {
      case (#err(reason)) {
        Logger.log(#_debug, ?"SlackEventIntake", "Skipping event: " # reason);
        #skipped(reason);
      };
      case (#ok(event)) {
        switch (EventStoreModel.enqueue(eventStore, event)) {
          case (#duplicate) {
            Logger.log(#_debug, ?"SlackEventIntake", "Duplicate event: " # event.eventId);
            #duplicate;
          };
          case (#ok) {
            Logger.log(#_debug, ?"SlackEventIntake", "Enqueued event: " # event.eventId);
            #enqueued(event.eventId);
          };
        };
      };
    };
  };

};
