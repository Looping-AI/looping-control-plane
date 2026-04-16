import Array "mo:core/Array";
import Time "mo:core/Time";
import Text "mo:core/Text";
import Types "../types";
import SecretModel "../models/secret-model";
import ChannelHistoryModel "../models/channel-history-model";
import AgentModel "../models/agent-model";
import OrgAdminAgent "../agents/admin/org-admin-agent";
import SessionModel "../models/session-model";

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

  /// Typed per-category context union — mirrors AgentCategory nesting.
  /// - `#_system(#admin)`      → AdminAgentCtx (workspace management)
  /// - `#_system(#onboarding)` → stub, handles DMs to the Slack App (planned)
  /// - `#custom`              → stub, user-defined agent
  public type AgentCtx = {
    #_system : { #admin : AdminAgentCtx; #onboarding };
    #custom;
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
  // `channelHistory` provides the full channel history store for LLM context
  // assembly, scoped by `channelId` and optionally `threadTs`.
  //
  // Returns the LLM's final text response. The caller is responsible for
  // persisting the user message and agent response to the channel history store.
  public func orchestrateAgentTalk(
    agent : AgentModel.AgentRecord,
    secrets : SecretModel.SecretsState,
    slackUserId : ?Text,
    channelHistory : ChannelHistoryModel.ChannelHistoryStore,
    channelId : Text,
    threadTs : ?Text,
    agentCtx : AgentCtx,
    workspaceKey : [Nat8],
    orgKey : [Nat8],
    turnId : Text,
    sessionStores : SessionModel.SessionStores,
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
      case (#_system(#onboarding)) {
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
      case (#custom) {
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
    let guardWorkspaceId : Nat = switch (agentCtx) {
      case (#_system(#admin(_))) { 0 };
      case (#_system(#onboarding) or #custom) { 0 }; // unreachable — handled above
    };

    // Resolve the LLM API key with 3-level cascade:
    //   1. agent secretOverrides → custom key in the agent's workspace
    //   2. direct workspace secret
    //   3. fall back to org workspace (workspaceId 0)
    let apiKey = SecretModel.resolveSecret(secrets, agent, guardWorkspaceId, #openRouterApiKey, workspaceKey, orgKey, { slackUserId; agentId = ?agent.id; operation = "agent-orchestrator" });

    // Dispatch to the category orchestrator.
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
          case (#_system(#admin(ctx))) {
            await OrgAdminAgent.process(
              agent,
              channelHistory,
              channelId,
              threadTs,
              ctx,
              key,
              turnId,
              sessionStores,
            );
          };
          case (#_system(#onboarding) or #custom) {
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
