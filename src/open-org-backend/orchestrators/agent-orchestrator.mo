import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import SecretModel "../models/secret-model";
import ConversationModel "../models/conversation-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import AgentModel "../models/agent-model";
import OrgAdminAgent "../agents/admin/org-admin-agent";
import McpToolRegistry "../tools/mcp-tool-registry";

module {

  // Orchestrate the agent talk request after validation.
  //
  // Accepts the already-resolved `agent` from the caller (AgentRouter) — no
  // internal registry lookup is performed.  This removes the redundant
  // `getFirstByCategory(#admin, ...)` call that was present in the old
  // WorkspaceAdminOrchestrator.
  //
  // `conversationEntry` provides the timeline entry (from the conversation store)
  // to use as LLM context. Pass `null` when no history exists or is needed.
  //
  // Returns the LLM's final text response. The caller is responsible for
  // persisting the user message and agent response to the conversation store.
  public func orchestrateAgentTalk(
    agent : AgentModel.AgentRecord,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    workspaceSecrets : ?Map.Map<Types.SecretId, SecretModel.EncryptedSecret>,
    conversationEntry : ?ConversationModel.TimelineEntry,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    encryptionKey : [Nat8],
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
    // Derive the secretId from the agent's llmModel
    let secretId = AgentModel.llmModelToSecretId(agent.llmModel);

    // Guard: ensure this agent is allowed to access the secret for this workspace
    if (not AgentModel.isSecretAllowed(agent, workspaceId, secretId)) {
      return #err({
        message = "Agent \"" # agent.name # "\" does not have permission to access the LLM API key for workspace " # Nat.toText(workspaceId) # ".";
        steps = [];
      });
    };

    // Decrypt the LLM API key using the provided encryption key
    let apiKey = SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, secretId);

    // Dispatch to provider-specific agent based on the agent's llmModel
    switch (agent.llmModel) {
      case (#groq(_)) {
        switch (apiKey) {
          case (null) {
            #err({
              message = "No Groq API key found for agent talk. Please store the API key first.";
              steps = [];
            });
          };
          case (?key) {
            let serviceResult = await OrgAdminAgent.process(
              agent,
              mcpToolRegistry,
              conversationEntry,
              workspaceValueStreamsState,
              valueStreamsMap,
              workspaceObjectivesMap,
              metricsRegistryState,
              metricDatapoints,
              workspaceId,
              message,
              key,
            );
            switch (serviceResult) {
              case (#ok({ response; steps = serviceSteps })) {
                // Emit an observability step for the successful LLM call
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
