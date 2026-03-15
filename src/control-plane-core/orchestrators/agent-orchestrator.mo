import Array "mo:core/Array";
import Time "mo:core/Time";
import Text "mo:core/Text";
import Types "../types";
import SecretModel "../models/secret-model";
import ConversationModel "../models/conversation-model";
import AgentModel "../models/agent-model";
import OrgAdminAgent "../agents/admin/org-admin-agent";
import WorkPlanningAgent "../agents/planning/work-planning-agent";
import McpToolRegistry "../tools/mcp-tool-registry";

module {

  // ─── Context types ───────────────────────────────────────────────────────────
  //
  // Each agent category has its own context record carrying exactly the data that
  // category needs.  The `AgentCtx` variant selects the active category at dispatch
  // time and ensures the router passes the right context to the right agent.
  //
  // These types live here (the bottom of the dispatch chain) to avoid circular
  // imports: AgentRouter imports AgentOrchestrator and re-exports these types as
  // aliases for callers such as MessageHandler.

  /// Context for the org-admin agent — workspace lifecycle and channel-anchor management.
  public type AdminAgentCtx = OrgAdminAgent.AdminCtx;

  /// Context for the work-planning agent — value streams, metrics, and objectives.
  public type PlanningAgentCtx = WorkPlanningAgent.PlanningCtx;

  /// Typed per-category context union.
  /// - `#admin`         → AdminAgentCtx (workspace management)
  /// - `#planning`      → PlanningAgentCtx (value streams / metrics / objectives)
  /// - `#research`      → stub, Phase 5
  /// - `#communication` → stub, Phase 5
  public type AgentCtx = {
    #admin : AdminAgentCtx;
    #planning : PlanningAgentCtx;
    #research;
    #communication;
  };

  // ─── Orchestration ───────────────────────────────────────────────────────────

  // Orchestrate the agent talk request after validation.
  //
  // Accepts the already-resolved `agent` and `agentCtx` from AgentRouter — no
  // internal registry lookup is performed.
  //
  // `agentCtx` carries the category-specific data slice.  The variant tag must
  // match `agent.category`; the router enforces this before calling here.
  //
  // `conversationEntry` provides the timeline entry (from the conversation store)
  // to use as LLM context. Pass `null` when no history exists or is needed.
  //
  // Returns the LLM's final text response. The caller is responsible for
  // persisting the user message and agent response to the conversation store.
  public func orchestrateAgentTalk(
    agent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    secrets : SecretModel.SecretsState,
    slackUserId : ?Text,
    conversationEntry : ?ConversationModel.TimelineEntry,
    agentCtx : AgentCtx,
    message : Text,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
  ) : async {
    #ok : {
      response : Text;
      steps : [Types.ProcessingStep];
    };
    #err : {
      message : Text;
      steps : [Types.ProcessingStep];
    };
  } {
    // Stub categories return early before touching secrets
    switch (agentCtx) {
      case (#research) {
        let step : Types.ProcessingStep = {
          action = "orchestrate";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        return #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
      case (#communication) {
        let step : Types.ProcessingStep = {
          action = "orchestrate";
          result = #err("category service not yet implemented");
          timestamp = Time.now();
        };
        return #err({
          message = "category service not yet implemented";
          steps = [step];
        });
      };
      case _ {};
    };

    // Extract the workspace ID relevant to the secret guard:
    //   admin agents operate at workspace-0 (org level)
    //   planning agents are scoped to their workspace
    let guardWorkspaceId : Nat = switch (agentCtx) {
      case (#admin(_)) { 0 };
      case (#planning(ctx)) { ctx.workspaceId };
      case (#research or #communication) { 0 }; // unreachable — handled above
    };

    // Derive the secretId from the agent's llmModel
    let secretId = AgentModel.llmModelToSecretId(agent.llmModel);

    // Resolve the LLM API key with 3-level cascade:
    //   1. agent secretOverrides → custom key in the agent's workspace
    //   2. direct workspace secret
    //   3. fall back to org workspace (workspaceId 0)
    let apiKey = SecretModel.resolveSecret(secrets, agent, guardWorkspaceId, secretId, workspaceKey, orgKey, { slackUserId; agentId = ?agent.id; operation = "agent-orchestrator" });

    // Dispatch to provider-specific agent based on the agent's llmModel
    switch (agent.llmModel) {
      case (#openRouter(_)) {
        switch (apiKey) {
          case (null) {
            #err({
              message = "No OpenRouter API key found for agent talk. Please store the API key first.";
              steps = [];
            });
          };
          case (?key) {
            let serviceResult : {
              #ok : { response : Text; steps : [Types.ProcessingStep] };
              #err : { message : Text; steps : [Types.ProcessingStep] };
            } = switch (agentCtx) {
              case (#admin(ctx)) {
                await OrgAdminAgent.process(
                  agent,
                  mcpToolRegistry,
                  conversationEntry,
                  ctx,
                  message,
                  key,
                );
              };
              case (#planning(ctx)) {
                await WorkPlanningAgent.process(
                  agent,
                  mcpToolRegistry,
                  conversationEntry,
                  ctx,
                  message,
                  key,
                );
              };
              case (#research or #communication) {
                // unreachable — handled before secret guard
                #err({
                  message = "category service not yet implemented";
                  steps = [];
                });
              };
            };
            switch (serviceResult) {
              case (#ok({ response; steps = serviceSteps })) {
                let llmStep : Types.ProcessingStep = {
                  action = "llm_call";
                  result = #ok;
                  timestamp = Time.now();
                };
                let allSteps = Array.concat(serviceSteps, [llmStep]);
                #ok({ response; steps = allSteps });
              };
              case (#err({ message = errMsg; steps = serviceSteps })) {
                let llmStep : Types.ProcessingStep = {
                  action = "llm_call";
                  result = #err(errMsg);
                  timestamp = Time.now();
                };
                let allSteps = Array.concat(serviceSteps, [llmStep]);
                #err({ message = errMsg; steps = allSteps });
              };
            };
          };
        };
      };
    };
  };
};
