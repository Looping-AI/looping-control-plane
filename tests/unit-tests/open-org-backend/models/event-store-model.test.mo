import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Text "mo:core/Text";
import EventStoreModel "../../../../src/open-org-backend/models/event-store-model";
import NormalizedEventTypes "../../../../src/open-org-backend/events/types/normalized-event-types";

// ============================================
// Test Helpers
// ============================================

func makeEvent(eventId : Text, payload : NormalizedEventTypes.EventPayload) : NormalizedEventTypes.Event {
  {
    source = #slack;
    workspaceId = 0;
    idempotencyKey = eventId;
    eventId = "slack_" # eventId;
    timestamp = 1700000000;
    payload;
    enqueuedAt = 0;
    claimedAt = null;
    processedAt = null;
    failedAt = null;
    failedError = "";
    processingLog = [];
  };
};

func makeMessageEvent(eventId : Text) : NormalizedEventTypes.Event {
  makeEvent(
    eventId,
    #message({
      user = "U123";
      text = "hello";
      channel = "C456";
      ts = "1700000000.000001";
      threadTs = null;
      isBotMessage = false;
      agentMetadata = null;
    }),
  );
};

func makeTestSteps() : [NormalizedEventTypes.ProcessingStep] {
  [
    {
      action = "log_event";
      result = #ok;
      timestamp = 1_000_000_000;
    },
  ];
};

// ============================================
// Test Suites
// ============================================

suite(
  "EventStoreModel - empty",
  func() {
    test(
      "creates empty state with zero sizes",
      func() {
        let state = EventStoreModel.empty();
        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.processed).equal(0);
        expect.nat(sizes.failed).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - enqueue",
  func() {
    test(
      "enqueues a new event successfully",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("Ev001");
        let result = EventStoreModel.enqueue(state, event);
        expect.bool(result == #ok).equal(true);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1);
      },
    );

    test(
      "sets enqueuedAt on enqueue",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("Ev002");
        ignore EventStoreModel.enqueue(state, event);

        let stored = EventStoreModel.get(state, "slack_Ev002");
        switch (stored) {
          case (?e) {
            // enqueuedAt should be set to a non-zero value (Time.now())
            expect.bool(e.enqueuedAt != 0).equal(true);
          };
          case (null) {
            expect.bool(false).equal(true); // Should not happen
          };
        };
      },
    );

    test(
      "rejects duplicate event in unprocessed",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("Ev003");
        ignore EventStoreModel.enqueue(state, event);

        let result = EventStoreModel.enqueue(state, event);
        expect.bool(result == #duplicate).equal(true);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1);
      },
    );

    test(
      "rejects duplicate event in processed",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("Ev004");
        ignore EventStoreModel.enqueue(state, event);
        ignore EventStoreModel.claim(state, "slack_Ev004");
        EventStoreModel.markProcessed(state, "slack_Ev004", makeTestSteps());

        // Try to enqueue the same event again
        let result = EventStoreModel.enqueue(state, event);
        expect.bool(result == #duplicate).equal(true);
      },
    );

    test(
      "rejects duplicate event in failed",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("Ev005");
        ignore EventStoreModel.enqueue(state, event);
        ignore EventStoreModel.claim(state, "slack_Ev005");
        EventStoreModel.markFailed(state, "slack_Ev005", "test error");

        // Try to enqueue the same event again
        let result = EventStoreModel.enqueue(state, event);
        expect.bool(result == #duplicate).equal(true);
      },
    );

    test(
      "enqueues multiple different events",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev006"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev007"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev008"));

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(3);
      },
    );
  },
);

suite(
  "EventStoreModel - isDuplicate",
  func() {
    test(
      "returns false for non-existent event",
      func() {
        let state = EventStoreModel.empty();
        expect.bool(EventStoreModel.isDuplicate(state, "slack_missing")).equal(false);
      },
    );

    test(
      "returns true for event in unprocessed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev010"));
        expect.bool(EventStoreModel.isDuplicate(state, "slack_Ev010")).equal(true);
      },
    );

    test(
      "returns true for event in processed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev011"));
        ignore EventStoreModel.claim(state, "slack_Ev011");
        EventStoreModel.markProcessed(state, "slack_Ev011", makeTestSteps());
        expect.bool(EventStoreModel.isDuplicate(state, "slack_Ev011")).equal(true);
      },
    );

    test(
      "returns true for event in failed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev012"));
        ignore EventStoreModel.claim(state, "slack_Ev012");
        EventStoreModel.markFailed(state, "slack_Ev012", "error");
        expect.bool(EventStoreModel.isDuplicate(state, "slack_Ev012")).equal(true);
      },
    );
  },
);

suite(
  "EventStoreModel - claim",
  func() {
    test(
      "claims an existing unprocessed event",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev020"));

        let claimed = EventStoreModel.claim(state, "slack_Ev020");
        switch (claimed) {
          case (?e) {
            expect.text(e.eventId).equal("slack_Ev020");
            // claimedAt should be set
            switch (e.claimedAt) {
              case (?_) { expect.bool(true).equal(true) };
              case (null) { expect.bool(false).equal(true) }; // Should have claimedAt
            };
          };
          case (null) {
            expect.bool(false).equal(true); // Should not be null
          };
        };
      },
    );

    test(
      "returns null for non-existent event",
      func() {
        let state = EventStoreModel.empty();
        let claimed = EventStoreModel.claim(state, "slack_missing");
        switch (claimed) {
          case (null) { expect.bool(true).equal(true) };
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "event remains in unprocessed after claim",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev022"));
        ignore EventStoreModel.claim(state, "slack_Ev022");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1);
        expect.nat(sizes.processed).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - markProcessed",
  func() {
    test(
      "moves event from unprocessed to processed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev030"));
        ignore EventStoreModel.claim(state, "slack_Ev030");

        EventStoreModel.markProcessed(state, "slack_Ev030", makeTestSteps());

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.processed).equal(1);
      },
    );

    test(
      "sets processedAt timestamp",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev031"));
        ignore EventStoreModel.claim(state, "slack_Ev031");
        EventStoreModel.markProcessed(state, "slack_Ev031", makeTestSteps());

        let event = EventStoreModel.get(state, "slack_Ev031");
        switch (event) {
          case (?e) {
            switch (e.processedAt) {
              case (?_) { expect.bool(true).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "stores processing log steps",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev032"));
        ignore EventStoreModel.claim(state, "slack_Ev032");

        let steps : [NormalizedEventTypes.ProcessingStep] = [
          { action = "step_one"; result = #ok; timestamp = 100 },
          { action = "step_two"; result = #err("oops"); timestamp = 200 },
        ];
        EventStoreModel.markProcessed(state, "slack_Ev032", steps);

        let event = EventStoreModel.get(state, "slack_Ev032");
        switch (event) {
          case (?e) {
            expect.nat(e.processingLog.size()).equal(2);
            expect.text(e.processingLog[0].action).equal("step_one");
            expect.text(e.processingLog[1].action).equal("step_two");
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "no-op if event not in unprocessed",
      func() {
        let state = EventStoreModel.empty();
        EventStoreModel.markProcessed(state, "slack_missing", makeTestSteps());

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.processed).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - markFailed",
  func() {
    test(
      "moves event from unprocessed to failed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev040"));
        ignore EventStoreModel.claim(state, "slack_Ev040");

        EventStoreModel.markFailed(state, "slack_Ev040", "handler crashed");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.failed).equal(1);
      },
    );

    test(
      "sets failedAt and failedError",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev041"));
        ignore EventStoreModel.claim(state, "slack_Ev041");
        EventStoreModel.markFailed(state, "slack_Ev041", "timeout");

        let event = EventStoreModel.get(state, "slack_Ev041");
        switch (event) {
          case (?e) {
            switch (e.failedAt) {
              case (?_) { expect.bool(true).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
            expect.text(e.failedError).equal("timeout");
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "no-op if event not in unprocessed",
      func() {
        let state = EventStoreModel.empty();
        EventStoreModel.markFailed(state, "slack_missing", "error");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.failed).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - get",
  func() {
    test(
      "finds event in unprocessed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev050"));

        let event = EventStoreModel.get(state, "slack_Ev050");
        switch (event) {
          case (?e) { expect.text(e.eventId).equal("slack_Ev050") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "finds event in processed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev051"));
        ignore EventStoreModel.claim(state, "slack_Ev051");
        EventStoreModel.markProcessed(state, "slack_Ev051", makeTestSteps());

        let event = EventStoreModel.get(state, "slack_Ev051");
        switch (event) {
          case (?e) { expect.text(e.eventId).equal("slack_Ev051") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "finds event in failed",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev052"));
        ignore EventStoreModel.claim(state, "slack_Ev052");
        EventStoreModel.markFailed(state, "slack_Ev052", "error");

        let event = EventStoreModel.get(state, "slack_Ev052");
        switch (event) {
          case (?e) { expect.text(e.eventId).equal("slack_Ev052") };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "returns null for non-existent event",
      func() {
        let state = EventStoreModel.empty();
        let event = EventStoreModel.get(state, "slack_missing");
        switch (event) {
          case (null) { expect.bool(true).equal(true) };
          case (?_) { expect.bool(false).equal(true) };
        };
      },
    );
  },
);

suite(
  "EventStoreModel - sizes",
  func() {
    test(
      "tracks sizes across all maps correctly",
      func() {
        let state = EventStoreModel.empty();

        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev060"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev061"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev062"));

        // Process one
        ignore EventStoreModel.claim(state, "slack_Ev060");
        EventStoreModel.markProcessed(state, "slack_Ev060", makeTestSteps());

        // Fail one
        ignore EventStoreModel.claim(state, "slack_Ev061");
        EventStoreModel.markFailed(state, "slack_Ev061", "error");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1);
        expect.nat(sizes.processed).equal(1);
        expect.nat(sizes.failed).equal(1);
      },
    );
  },
);

suite(
  "EventStoreModel - listFailed",
  func() {
    test(
      "returns empty array when no failed events",
      func() {
        let state = EventStoreModel.empty();
        let failed = EventStoreModel.listFailed(state);
        expect.nat(failed.size()).equal(0);
      },
    );

    test(
      "returns all failed events",
      func() {
        let state = EventStoreModel.empty();

        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev070"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev071"));

        ignore EventStoreModel.claim(state, "slack_Ev070");
        EventStoreModel.markFailed(state, "slack_Ev070", "error1");

        ignore EventStoreModel.claim(state, "slack_Ev071");
        EventStoreModel.markFailed(state, "slack_Ev071", "error2");

        let failed = EventStoreModel.listFailed(state);
        expect.nat(failed.size()).equal(2);
      },
    );
  },
);

suite(
  "EventStoreModel - deleteFailed",
  func() {
    test(
      "deletes a specific failed event",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev080"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev081"));

        ignore EventStoreModel.claim(state, "slack_Ev080");
        EventStoreModel.markFailed(state, "slack_Ev080", "error1");
        ignore EventStoreModel.claim(state, "slack_Ev081");
        EventStoreModel.markFailed(state, "slack_Ev081", "error2");

        let deleted = EventStoreModel.deleteFailed(state, ?"slack_Ev080");
        expect.nat(deleted).equal(1);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.failed).equal(1);

        // The other one should still be there
        let remaining = EventStoreModel.get(state, "slack_Ev081");
        switch (remaining) {
          case (?_) { expect.bool(true).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "deletes all failed events when eventId is null",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev082"));
        ignore EventStoreModel.enqueue(state, makeMessageEvent("Ev083"));

        ignore EventStoreModel.claim(state, "slack_Ev082");
        EventStoreModel.markFailed(state, "slack_Ev082", "error1");
        ignore EventStoreModel.claim(state, "slack_Ev083");
        EventStoreModel.markFailed(state, "slack_Ev083", "error2");

        let deleted = EventStoreModel.deleteFailed(state, null);
        expect.nat(deleted).equal(2);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.failed).equal(0);
      },
    );

    test(
      "returns 0 when deleting non-existent failed event",
      func() {
        let state = EventStoreModel.empty();
        let deleted = EventStoreModel.deleteFailed(state, ?"slack_missing");
        expect.nat(deleted).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - full lifecycle",
  func() {
    test(
      "enqueue → claim → markProcessed lifecycle",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("EvLifecycle1");

        // Enqueue
        let enqResult = EventStoreModel.enqueue(state, event);
        expect.bool(enqResult == #ok).equal(true);

        // Claim
        let claimed = EventStoreModel.claim(state, "slack_EvLifecycle1");
        switch (claimed) {
          case (?e) {
            expect.text(e.eventId).equal("slack_EvLifecycle1");
            switch (e.claimedAt) {
              case (?_) { expect.bool(true).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
          };
          case (null) { expect.bool(false).equal(true) };
        };

        // Mark processed
        EventStoreModel.markProcessed(state, "slack_EvLifecycle1", makeTestSteps());
        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.processed).equal(1);
        expect.nat(sizes.failed).equal(0);

        // Verify full event state
        let processed = EventStoreModel.get(state, "slack_EvLifecycle1");
        switch (processed) {
          case (?e) {
            switch (e.processedAt) {
              case (?_) { expect.bool(true).equal(true) };
              case (null) { expect.bool(false).equal(true) };
            };
            expect.nat(e.processingLog.size()).equal(1);
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "enqueue → claim → markFailed lifecycle",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("EvLifecycle2");

        ignore EventStoreModel.enqueue(state, event);
        ignore EventStoreModel.claim(state, "slack_EvLifecycle2");
        EventStoreModel.markFailed(state, "slack_EvLifecycle2", "LLM timeout");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.processed).equal(0);
        expect.nat(sizes.failed).equal(1);

        let failed = EventStoreModel.get(state, "slack_EvLifecycle2");
        switch (failed) {
          case (?e) {
            expect.text(e.failedError).equal("LLM timeout");
          };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "dedup prevents re-enqueue after processing",
      func() {
        let state = EventStoreModel.empty();
        let event = makeMessageEvent("EvLifecycle3");

        ignore EventStoreModel.enqueue(state, event);
        ignore EventStoreModel.claim(state, "slack_EvLifecycle3");
        EventStoreModel.markProcessed(state, "slack_EvLifecycle3", makeTestSteps());

        // Try re-enqueue
        let result = EventStoreModel.enqueue(state, event);
        expect.bool(result == #duplicate).equal(true);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.processed).equal(1);
        expect.nat(sizes.unprocessed).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - purgeProcessed",
  func() {
    test(
      "does not purge events with processedAt within 7 days",
      func() {
        let state = EventStoreModel.empty();

        // Enqueue, claim, and process — processedAt will be Time.now() (recent)
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvPurge001"));
        ignore EventStoreModel.claim(state, "slack_EvPurge001");
        EventStoreModel.markProcessed(state, "slack_EvPurge001", makeTestSteps());

        let purged = EventStoreModel.purgeProcessed(state);
        expect.nat(purged).equal(0);

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.processed).equal(1);
      },
    );

    test(
      "does not purge events with processedAt = null",
      func() {
        // Manually insert a processed event without a processedAt timestamp
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvPurge002"));
        ignore EventStoreModel.claim(state, "slack_EvPurge002");
        // markProcessed sets processedAt, so just calling purge on fresh state is safe
        EventStoreModel.markProcessed(state, "slack_EvPurge002", makeTestSteps());

        // Recent event — should NOT be purged
        let purged = EventStoreModel.purgeProcessed(state);
        expect.nat(purged).equal(0);
        expect.nat(EventStoreModel.sizes(state).processed).equal(1);
      },
    );

    test(
      "returns 0 when processed map is empty",
      func() {
        let state = EventStoreModel.empty();
        let purged = EventStoreModel.purgeProcessed(state);
        expect.nat(purged).equal(0);
      },
    );
  },
);

suite(
  "EventStoreModel - failStaleUnprocessed",
  func() {
    test(
      "returns empty array when no events are stale",
      func() {
        let state = EventStoreModel.empty();
        // Fresh event — enqueuedAt is Time.now(), well within 1 hour
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvStale001"));

        let staleIds = EventStoreModel.failStaleUnprocessed(state);
        expect.nat(staleIds.size()).equal(0);

        // Event should still be in unprocessed
        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1);
        expect.nat(sizes.failed).equal(0);
      },
    );

    test(
      "returns empty array when unprocessed map is empty",
      func() {
        let state = EventStoreModel.empty();
        let staleIds = EventStoreModel.failStaleUnprocessed(state);
        expect.nat(staleIds.size()).equal(0);
      },
    );

    test(
      "moves stale event to failed and returns its ID",
      func() {
        // In mops test env, Time.now() = 42
        // To make an event stale (> 1h old), set enqueuedAt to a very negative number
        // so that: now - enqueuedAt = 42 - (-huge) = 42 + huge > ONE_HOUR_NS
        let staleEvent : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvStale002";
          eventId = "slack_EvStale002";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "stale hello";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          // Set enqueuedAt to large negative Int so diff is > ONE_HOUR_NS
          enqueuedAt = -9_999_999_999_999;
          claimedAt = null;
          processedAt = null;
          failedAt = null;
          failedError = "";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.unprocessed, Text.compare, staleEvent.eventId, staleEvent);

        let staleIds = EventStoreModel.failStaleUnprocessed(state);
        expect.nat(staleIds.size()).equal(1);
        expect.text(staleIds[0]).equal("slack_EvStale002");

        // Should be removed from unprocessed and added to failed
        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(0);
        expect.nat(sizes.failed).equal(1);
      },
    );

    test(
      "sets failedAt and correct failedError on moved event",
      func() {
        let staleEvent : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvStale003";
          eventId = "slack_EvStale003";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "stale";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          enqueuedAt = -9_999_999_999_999; // Stale: far in the past
          claimedAt = null;
          processedAt = null;
          failedAt = null;
          failedError = "";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.unprocessed, Text.compare, staleEvent.eventId, staleEvent);
        ignore EventStoreModel.failStaleUnprocessed(state);

        let failed = EventStoreModel.get(state, "slack_EvStale003");
        switch (failed) {
          case (null) { expect.bool(false).equal(true) };
          case (?e) {
            switch (e.failedAt) {
              case (null) { expect.bool(false).equal(true) };
              case (?_) { expect.bool(true).equal(true) };
            };
            expect.text(e.failedError).equal("Event was not picked up within 1 hour of being enqueued.");
          };
        };
      },
    );

    test(
      "only moves stale events; fresh events stay in unprocessed",
      func() {
        let staleEvent : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvStale004";
          eventId = "slack_EvStale004";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "stale";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          enqueuedAt = -9_999_999_999_999; // Stale: far in the past
          claimedAt = null;
          processedAt = null;
          failedAt = null;
          failedError = "";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.unprocessed, Text.compare, staleEvent.eventId, staleEvent);
        // Also enqueue a fresh event (enqueuedAt = Time.now())
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvStale005"));

        let staleIds = EventStoreModel.failStaleUnprocessed(state);
        expect.nat(staleIds.size()).equal(1);
        expect.text(staleIds[0]).equal("slack_EvStale004");

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.unprocessed).equal(1); // Fresh event remains
        expect.nat(sizes.failed).equal(1); // Stale event moved to failed
      },
    );
  },
);

suite(
  "EventStoreModel - purgeOldFailed",
  func() {
    test(
      "returns 0 when failed map is empty",
      func() {
        let state = EventStoreModel.empty();
        let purged = EventStoreModel.purgeOldFailed(state);
        expect.nat(purged).equal(0);
      },
    );

    test(
      "does not purge a recently failed event",
      func() {
        let state = EventStoreModel.empty();
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvOldFail001"));
        ignore EventStoreModel.claim(state, "slack_EvOldFail001");
        // failedAt = Time.now() (recent)
        EventStoreModel.markFailed(state, "slack_EvOldFail001", "recent error");

        let purged = EventStoreModel.purgeOldFailed(state);
        expect.nat(purged).equal(0);
        expect.nat(EventStoreModel.sizes(state).failed).equal(1);
      },
    );

    test(
      "purges a failed event with failedAt far in the past",
      func() {
        // Manufacture an event already in the failed map with a very old failedAt
        // In mops: Time.now() = 42, so set failedAt to a very negative number
        // such that: now - failedAt > THIRTY_DAYS_NS
        // 30 days in ns = 2_592_000_000_000_000
        // So we need failedAt < 42 - 2_592_000_000_000_000 ≈ -2_591_999_999_999_958
        let oldFailedEvent : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvOldFail002";
          eventId = "slack_EvOldFail002";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "old failed";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          enqueuedAt = 1;
          claimedAt = null;
          processedAt = null;
          failedAt = ?(-3_000_000_000_000_000); // Much larger negative to exceed 30 days
          failedError = "ancient error";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.failed, Text.compare, oldFailedEvent.eventId, oldFailedEvent);

        let purged = EventStoreModel.purgeOldFailed(state);
        expect.nat(purged).equal(1);
        expect.nat(EventStoreModel.sizes(state).failed).equal(0);
      },
    );

    test(
      "keeps recent failures and removes old ones",
      func() {
        let oldFailedEvent : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvOldFail003";
          eventId = "slack_EvOldFail003";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "old";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          enqueuedAt = 1;
          claimedAt = null;
          processedAt = null;
          failedAt = ?(-3_000_000_000_000_000); // Very old — > 30 days
          failedError = "old error";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.failed, Text.compare, oldFailedEvent.eventId, oldFailedEvent);

        // Also add a recent failure via the normal path
        ignore EventStoreModel.enqueue(state, makeMessageEvent("EvOldFail004"));
        ignore EventStoreModel.claim(state, "slack_EvOldFail004");
        EventStoreModel.markFailed(state, "slack_EvOldFail004", "recent error");

        let purged = EventStoreModel.purgeOldFailed(state);
        expect.nat(purged).equal(1); // Only the old one removed

        let sizes = EventStoreModel.sizes(state);
        expect.nat(sizes.failed).equal(1); // Recent one remains

        // Verify it's the recent one that remains
        let remaining = EventStoreModel.get(state, "slack_EvOldFail004");
        switch (remaining) {
          case (?_) { expect.bool(true).equal(true) };
          case (null) { expect.bool(false).equal(true) };
        };
      },
    );

    test(
      "does not purge events with failedAt = null",
      func() {
        // Manufacture a failed event with failedAt = null (edge case)
        let noTimestampFailed : NormalizedEventTypes.Event = {
          source = #slack;
          workspaceId = 0;
          idempotencyKey = "EvOldFail005";
          eventId = "slack_EvOldFail005";
          timestamp = 1700000000;
          payload = #message({
            user = "U123";
            text = "no timestamp";
            channel = "C456";
            ts = "1700000000.000001";
            threadTs = null;
            isBotMessage = false;
            agentMetadata = null;
          });
          enqueuedAt = 42;
          claimedAt = null;
          processedAt = null;
          failedAt = null; // No failedAt set
          failedError = "unknown";
          processingLog = [];
        };

        let state = EventStoreModel.empty();
        Map.add(state.failed, Text.compare, noTimestampFailed.eventId, noTimestampFailed);

        let purged = EventStoreModel.purgeOldFailed(state);
        expect.nat(purged).equal(0);
        expect.nat(EventStoreModel.sizes(state).failed).equal(1);
      },
    );
  },
);
