import { test; suite; expect } "mo:test";
import NormalizedEventTypes "../../../../src/open-org-backend/events/types/normalized-event-types";

suite(
  "NormalizedEventTypes - sourcePrefix",
  func() {
    test(
      "returns 'slack' for #slack source",
      func() {
        let result = NormalizedEventTypes.sourcePrefix(#slack);
        expect.text(result).equal("slack");
      },
    );
  },
);

suite(
  "NormalizedEventTypes - buildEventId",
  func() {
    test(
      "builds correct eventId for Slack source",
      func() {
        let result = NormalizedEventTypes.buildEventId(#slack, "Ev0123ABCDEF");
        expect.text(result).equal("slack_Ev0123ABCDEF");
      },
    );

    test(
      "handles empty idempotencyKey",
      func() {
        let result = NormalizedEventTypes.buildEventId(#slack, "");
        expect.text(result).equal("slack_");
      },
    );

    test(
      "preserves special characters in idempotencyKey",
      func() {
        let result = NormalizedEventTypes.buildEventId(#slack, "Ev_with-special.chars");
        expect.text(result).equal("slack_Ev_with-special.chars");
      },
    );
  },
);
