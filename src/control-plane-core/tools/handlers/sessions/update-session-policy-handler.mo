import Json "mo:json";
import { str; obj; bool; int } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import SessionModel "../../../models/session-model";
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
            // Get current session (or create with defaults)
            let session = SessionModel.getOrCreateSession(stores, agentId);
            let currentPolicy = session.policy;

            // Parse optional overrides
            let budgetOpt : ?Nat = switch (Json.get(json, "summary_token_budget")) {
              case (?#number(#int n)) {
                if (n > 0) { ?Int.abs(n) } else { null };
              };
              case (null) { ?currentPolicy.summaryTokenBudget };
              case _ { null };
            };
            let truncOpt : ?Nat = switch (Json.get(json, "max_truncated_tokens")) {
              case (?#number(#int n)) {
                if (n > 0) { ?Int.abs(n) } else { null };
              };
              case (null) { ?currentPolicy.maxTruncatedTokens };
              case _ { null };
            };

            switch (budgetOpt, truncOpt) {
              case (?budget, ?trunc) {
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
              case _ {
                Helpers.buildErrorResponse("Invalid policy values: summary_token_budget and max_truncated_tokens must be positive integers when provided");
              };
            };
          };
        };
      };
    };
  };
};
