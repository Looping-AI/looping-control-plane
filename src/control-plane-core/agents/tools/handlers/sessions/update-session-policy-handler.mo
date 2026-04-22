import Json "mo:json";
import { str; obj; bool; int } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import SessionModel "../../../../models/session-model";
import Helpers "../handler-helpers";

module {
  public func handle(
    stores : SessionModel.SessionStores,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let agentIdOpt : ?Nat = switch (Json.get(json, "agent_id")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };

        switch (agentIdOpt) {
          case (null) {
            Helpers.buildErrorResponse("Missing or invalid required field: agent_id (must be a non-negative integer)");
          };
          case (?agentId) {
            // Validate optional overrides before any state-changing session lookup/creation.
            let budgetValue = Json.get(json, "summary_token_budget");
            let budgetValid = switch (budgetValue) {
              case (?#number(#int n)) { n > 0 };
              case (null) { true };
              case _ { false };
            };

            let truncValue = Json.get(json, "max_truncated_tokens");
            let truncValid = switch (truncValue) {
              case (?#number(#int n)) { n > 0 };
              case (null) { true };
              case _ { false };
            };

            if (not budgetValid or not truncValid) {
              Helpers.buildErrorResponse("Invalid policy values: summary_token_budget and max_truncated_tokens must be positive integers when provided");
            } else {
              // Only read/create the session after all request fields have been validated.
              let session = SessionModel.getOrCreateSession(stores, agentId);
              let currentPolicy = session.policy;

              let budget : Nat = switch (budgetValue) {
                case (?#number(#int n)) { Int.abs(n) };
                case _ { currentPolicy.summaryTokenBudget };
              };
              let trunc : Nat = switch (truncValue) {
                case (?#number(#int n)) { Int.abs(n) };
                case _ { currentPolicy.maxTruncatedTokens };
              };

              let newPolicy : SessionModel.SessionPolicy = {
                summaryTokenBudget = budget;
                maxTruncatedTokens = trunc;
              };
              ignore SessionModel.updateSessionPolicy(stores, agentId, newPolicy);

              Json.stringify(
                obj([
                  ("success", bool(true)),
                  ("agent_id", int(agentId)),
                  ("summary_token_budget", int(budget)),
                  ("max_truncated_tokens", int(trunc)),
                  ("message", str("Session policy updated for agent " # Nat.toText(agentId))),
                ]),
                null,
              );
            };
          };
        };
      };
    };
  };
};
