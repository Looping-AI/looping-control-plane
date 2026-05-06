import Text "mo:core/Text";
import Array "mo:core/Array";
import Json "mo:json";
import { str; obj; arr; int; float; bool; nullable } "mo:json";
import AgentModel "../models/agent-model";
import WorkflowTypes "../types/workflow";
import InstructionTypes "./instructions/instruction-types";

module {

  /// Map an AgentCategory to the appropriate AgentRole for instruction composition.
  ///
  ///   #_system(#admin)      →  #orgAdmin
  ///   #_system(#onboarding) →  #customAgent({ name; persona = null })
  ///   #custom              →  #customAgent({ name; persona = null })
  public func categoryToRole(
    category : AgentModel.AgentCategory,
    name : Text,
  ) : InstructionTypes.AgentRole {
    switch (category) {
      case (#_system(#admin)) { #orgAdmin };
      case (#_system(#onboarding)) {
        #customAgent({ name; persona = null });
      };
      case (#custom) {
        #customAgent({ name; persona = null });
      };
    };
  };

  /// Build scope grants based on agent category and ownership.
  ///
  ///   #_system(#admin) + org workspace (ownedBy=0) → 4 write grants (workspace, agents, slackQueue, session)
  ///   #_system(#admin) + other workspace           → 3 grants (workspace read, agents write, session write)
  ///   #_system(#onboarding) or #custom             → 1 per-agent read grant
  public func buildScopeGrants(agent : AgentModel.AgentRecord) : [WorkflowTypes.ScopeGrant] {
    switch (agent.category) {
      case (#_system(#admin)) {
        if (AgentModel.isOrgAdmin(agent)) {
          [
            #workspace({ access = #write }),
            #agents({ access = #write }),
            #slackQueue({ access = #write }),
            #session({ access = #write }),
          ];
        } else {
          [
            #workspace({ access = #read }),
            #agents({ access = #write }),
            #session({ access = #write }),
          ];
        };
      };
      case (#_system(#onboarding) or #custom) {
        [#agent({ id = agent.id; access = #read })];
      };
    };
  };

  /// Build the JSON string injected as a synthetic tool result into the LLM
  /// conversation on resume. Uses mo:json instead of hand-rolled concatenation.
  public func buildSyntheticToolResult(
    c : {
      humanSummary : Text;
      stepsDetail : [WorkflowTypes.SummarizedStep];
      status : WorkflowTypes.WorkflowStatus;
      stats : WorkflowTypes.WorkflowStats;
    }
  ) : Text {
    let statusText = switch (c.status) {
      case (#completed) { "completed" };
      case (#failed(_)) { "failed" };
      case (#roundLimitReached) { "roundLimitReached" };
    };

    let stepsJson = arr(
      Array.map<WorkflowTypes.SummarizedStep, Json.Json>(
        c.stepsDetail,
        func(s) {
          obj([("tool", str(s.tool)), ("summary", str(s.summary)), ("success", bool(s.success))]);
        },
      )
    );

    let statsJson = obj([
      ("durationNs", switch (c.stats.durationNs) { case (?d) { int(d) }; case null { nullable() } }),
      ("llmCalls", switch (c.stats.llmCalls) { case (?n) { int(n) }; case null { nullable() } }),
      ("inputTokens", switch (c.stats.inputTokens) { case (?n) { int(n) }; case null { nullable() } }),
      ("outputTokens", switch (c.stats.outputTokens) { case (?n) { int(n) }; case null { nullable() } }),
      ("estimatedDollarCost", switch (c.stats.estimatedDollarCost) { case (?f) { float(f) }; case null { nullable() } }),
    ]);

    Json.stringify(
      obj([
        ("status", str(statusText)),
        ("humanSummary", str(c.humanSummary)),
        ("stepsDetail", stepsJson),
        ("stats", statsJson),
      ]),
      null,
    );
  };

};
