import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Types "../types";
import SecretModel "../models/secret-model";
import KeyDerivationService "../services/key-derivation-service";
import ConversationModel "../models/conversation-model";
import ValueStreamModel "../models/value-stream-model";
import ObjectiveModel "../models/objective-model";
import MetricModel "../models/metric-model";
import GroqWorkspaceAdminService "../services/groq-workspace-admin-service";
import McpToolRegistry "../tools/mcp-tool-registry";
import Constants "../constants";

module {

  // Orchestrate the admin talk request after validation.
  //
  // Expects workspace-scoped inputs:
  //   - workspaceSecrets: result of Map.get(secrets, Nat.compare, workspaceId)
  //   - workspaceConversations: result of Map.get(adminConversations, Nat.compare, workspaceId)
  //     (must be the live List reference from the map so mutations persist)
  public func orchestrateAdminTalk(
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
    keyCache : KeyDerivationService.KeyCache,
  ) : async {
    #ok : {
      messages : [ConversationModel.Message];
      steps : [Types.ProcessingStep];
    };
    #err : Text;
  } {
    // Derive encryption key for the workspace, then decrypt the LLM API key
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let apiKey = SecretModel.getSecretScoped(workspaceSecrets, encryptionKey, Constants.ADMIN_TALK_SECRET);

    // Delegate to provider-specific service based on configured provider
    switch (Constants.ADMIN_TALK_PROVIDER) {
      case (#groq) {
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
      case (#openai) {
        #err("OpenAI integration not yet implemented.");
      };
    };
  };
};
