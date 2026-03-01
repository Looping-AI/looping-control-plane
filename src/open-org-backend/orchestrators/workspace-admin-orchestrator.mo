import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import SecretModel "../models/secret-model";
import ConversationModel "../models/conversation-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import AgentModel "../models/agent-model";
import GroqWorkspaceAdminService "../services/groq-workspace-admin-service";
import McpToolRegistry "../tools/mcp-tool-registry";

module {

  // Orchestrate the admin talk request after validation.
  //
  // Resolves the first #admin agent from the registry and uses its
  // llmModel and secretsAllowed to authenticate and dispatch the request.
  //
  // Expects workspace-scoped inputs:
  //   - workspaceSecrets: result of Map.get(secrets, Nat.compare, workspaceId)
  //   - workspaceConversations: result of Map.get(adminConversations, Nat.compare, workspaceId)
  //     (must be the live List reference from the map so mutations persist)
  public func orchestrateAdminTalk(
    agentRegistry : AgentModel.AgentRegistryState,
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    workspaceSecrets : ?Map.Map<Types.SecretId, SecretModel.EncryptedSecret>,
    workspaceConversations : List.List<ConversationModel.Message>,
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
      messages : [ConversationModel.Message];
      steps : [Types.ProcessingStep];
    };
    #err : Text;
  } {
    // Resolve the first #admin agent from the registry
    let agent = switch (AgentModel.getFirstByCategory(#admin, agentRegistry)) {
      case (null) {
        return #err("No admin agent registered. Please register an admin agent first.");
      };
      case (?a) { a };
    };

    // Derive the secretId and model string from the agent's llmModel
    let secretId = AgentModel.llmModelToSecretId(agent.llmModel);
    let modelText = AgentModel.llmModelToText(agent.llmModel);

    // Guard: ensure this agent is allowed to access the secret for this workspace
    if (not AgentModel.isSecretAllowed(agent, workspaceId, secretId)) {
      return #err(
        "Admin agent \"" # agent.name # "\" does not have permission to access the LLM API key for workspace " # Nat.toText(workspaceId) # "."
      );
    };

    // Decrypt the LLM API key using the provided encryption key
    let apiKey = SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, secretId);

    // Dispatch to provider-specific service based on the agent's llmModel
    switch (agent.llmModel) {
      case (#groq(_)) {
        switch (apiKey) {
          case (null) {
            #err("No Groq API key found for admin talk. Please store the API key first.");
          };
          case (?key) {
            let serviceResult = await GroqWorkspaceAdminService.executeAdminTalk(
              mcpToolRegistry,
              workspaceConversations,
              workspaceValueStreamsState,
              valueStreamsMap,
              workspaceObjectivesMap,
              metricsRegistryState,
              metricDatapoints,
              workspaceId,
              message,
              key,
              modelText,
            );
            // Emit an observability step for the LLM call result
            let step : Types.ProcessingStep = {
              action = "llm_call";
              result = switch (serviceResult) {
                case (#ok(_)) { #ok };
                case (#err(e)) { #err(e) };
              };
              timestamp = Time.now();
            };
            switch (serviceResult) {
              case (#ok(messages)) { #ok({ messages; steps = [step] }) };
              case (#err(_)) { #ok({ messages = []; steps = [step] }) };
            };
          };
        };
      };
    };
  };
};
