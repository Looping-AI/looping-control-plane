import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
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

  // Orchestrate the admin talk request after validation
  public func orchestrateAdminTalk(
    mcpToolRegistry : McpToolRegistry.McpToolRegistryState,
    apiKeys : Map.Map<Nat, Map.Map<Types.SecretId, SecretModel.EncryptedSecret>>,
    adminConversations : Map.Map<Nat, List.List<ConversationModel.Message>>,
    workspaceValueStreamsState : ValueStreamModel.WorkspaceValueStreamsState,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    metricsRegistryState : MetricModel.MetricsRegistryState,
    metricDatapoints : MetricModel.MetricDatapointsStore,
    workspaceId : Nat,
    message : Text,
    keyCache : KeyDerivationService.KeyCache,
  ) : async {
    #ok : [ConversationModel.Message];
    #err : Text;
  } {
    // Get api key (requires deriving encryption key for the workspace)
    let encryptionKey = await KeyDerivationService.getOrDeriveKey(keyCache, workspaceId);
    let apiKey = SecretModel.getSecret(apiKeys, encryptionKey, workspaceId, Constants.ADMIN_TALK_SECRET);

    // Delegate to provider-specific service based on configured provider
    switch (Constants.ADMIN_TALK_PROVIDER) {
      case (#groq) {
        switch (apiKey) {
          case (null) {
            #err("No Groq API key found for admin talk. Please store the API key first.");
          };
          case (?key) {
            await GroqWorkspaceAdminService.executeAdminTalk(
              mcpToolRegistry,
              adminConversations,
              workspaceValueStreamsState,
              valueStreamsMap,
              workspaceObjectivesMap,
              metricsRegistryState,
              metricDatapoints,
              workspaceId,
              message,
              key,
            );
          };
        };
      };
      case (#openai) {
        #err("OpenAI integration not yet implemented.");
      };
    };
  };
};
