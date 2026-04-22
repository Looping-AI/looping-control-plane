import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";
import Constants "../../constants";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import WebSearchHandler "./handlers/web-search-handler";
import StoreSecretHandler "./handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "./handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "./handlers/secrets/delete-secret-handler";
import GetEventStoreStatsHandler "./handlers/events/get-event-store-stats-handler";
import GetFailedEventsHandler "./handlers/events/get-failed-events-handler";
import DeleteFailedEventsHandler "./handlers/events/delete-failed-events-handler";
import SessionModel "../../models/session-model";
import UpdateSessionPolicyHandler "./handlers/sessions/update-session-policy-handler";
import DispatchWorkflowHandler "./handlers/dispatch-workflow-handler";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import EventStoreModel "../../models/event-store-model";

module {
  // ============================================
  // Function Tool Registry
  // ============================================
  //
  // Resource-based registry of function tools.
  // Tools are generated dynamically based on provided resources,
  // creating a natural allowlist mechanism.
  //
  // Each tool has its definition (what LLM sees) and handler (implementation).
  // Handlers are closures over provided resources.
  //
  // To add a new tool:
  // 1. Create a private function that returns FunctionTool
  // 2. Capture required resources in the closure
  // 3. Add it to getAll() with appropriate resource checks
  //
  // ============================================

  /// A function tool with definition and implementation
  public type FunctionTool = {
    definition : OpenRouterWrapper.Tool;
    handler : (Text) -> async Text;
  };

  /// Get all registered function tools available for the given resources
  public func getAll(resources : ToolTypes.ToolResources) : [FunctionTool] {
    let tools = List.empty<FunctionTool>();

    // ==========================================
    // WEB SEARCH TOOL - requires openRouterApiKey
    // ==========================================
    switch (resources.openRouterApiKey) {
      case (?apiKey) {
        List.add(tools, webSearchTool(apiKey));
      };
      case (null) {};
    };

    // ==========================================
    // SECRETS MANAGEMENT TOOLS - require secrets resource + userAuthContext + workspaceId
    // ==========================================
    switch (resources.secrets, resources.userAuthContext, resources.workspaceId) {
      case (?sec, ?uac, ?wsId) {
        // Read tools — always available when resource, user identity, and workspace are present
        List.add(tools, getWorkspaceSecretsTool(sec.state, uac, wsId));
        // Write tools — require write=true
        if (sec.write) {
          List.add(tools, storeSecretTool(sec.state, sec.keyCache, uac, wsId));
          List.add(tools, deleteSecretTool(sec.state, uac, wsId));
        };
      };
      case _ {};
    };

    // ==========================================
    // EVENT STORE TOOLS - require eventStore resource + userAuthContext
    // ==========================================
    switch (resources.eventStore, resources.userAuthContext) {
      case (?es, ?uac) {
        // Read tools — always available when resource and user identity are present
        List.add(tools, getEventStoreStatsTool(es.state, uac));
        List.add(tools, getFailedEventsTool(es.state, uac));
        // Write tools — require write=true
        if (es.write) {
          List.add(tools, deleteFailedEventsTool(es.state, uac));
        };
      };
      case _ {};
    };

    // ==========================================
    // SESSION POLICY TOOLS - require sessionStores resource with write
    // ==========================================
    switch (resources.sessionStores) {
      case (?ss) {
        if (ss.write) {
          List.add(tools, updateSessionPolicyTool(ss.stores));
        };
      };
      case (null) {};
    };

    // ==========================================
    // DISPATCH WORKFLOW TOOL - requires engineDispatch + envelopeContext
    // ==========================================
    switch (resources.engineDispatch, resources.envelopeContext) {
      case (?ed, ?ec) {
        List.add(tools, dispatchWorkflowTool(ed, ec, resources.triggerMessageText));
      };
      case _ {};
    };

    List.toArray(tools);
  };

  /// Get all tool definitions (for passing to LLM API)
  public func getAllDefinitions(resources : ToolTypes.ToolResources) : [OpenRouterWrapper.Tool] {
    Array.map<FunctionTool, OpenRouterWrapper.Tool>(
      getAll(resources),
      func(t : FunctionTool) : OpenRouterWrapper.Tool { t.definition },
    );
  };

  /// Lookup a function tool by name (with resources for closures)
  public func get(resources : ToolTypes.ToolResources, name : Text) : ?FunctionTool {
    Array.find<FunctionTool>(
      getAll(resources),
      func(t : FunctionTool) : Bool {
        t.definition.function.name == name;
      },
    );
  };

  /// Web search tool - requires openRouterApiKey
  private func webSearchTool(apiKey : Text) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "web_search";
          description = ?"Performs a web search using the OpenRouter web search plugin. Returns AI-analyzed search results. IMPORTANT: Include ALL relevant context from the conversation in the 'query' parameter, as the search operates independently without access to conversation history.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The search query with full context. Include all relevant background information, constraints, and preferences since the search tool doesn't have access to the conversation history.\"}},\"required\":[\"query\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await WebSearchHandler.handle(apiKey, args);
      };
    };
  };

  // ============================================
  // SECRETS MANAGEMENT TOOL IMPLEMENTATIONS
  // ============================================

  /// Get workspace secrets tool — always available when secrets resource + user identity + workspaceId are present
  private func getWorkspaceSecretsTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_workspace_secrets";
          description = ?"Lists the secret identifiers stored for the current workspace. Secret values are never returned — only the names of which secrets have been stored.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetWorkspaceSecretsHandler.handle(map, uac, workspaceId, args);
      };
    };
  };

  /// Store secret tool — requires secrets resource with write + user identity + workspaceId
  private func storeSecretTool(
    map : SecretModel.SecretsState,
    keyCache : KeyDerivationService.KeyCache,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "store_secret";
          description = ?"Encrypts and stores a secret for the current workspace. The Slack bot token (slackBotToken) requires org-admin access. LLM API keys (openRouterApiKey) can be stored by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"secretId\":{\"type\":\"string\",\"description\":\"Standard secret type: openRouterApiKey | anthropicApiKey | anthropicSetupToken | slackBotToken | slackSigningSecret. For custom keys use \'custom:<name>\' format.\"},\"secretValue\":{\"type\":\"string\",\"description\":\"The secret value to encrypt and store.\"}},\"required\":[\"secretId\",\"secretValue\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await StoreSecretHandler.handle(map, keyCache, uac, workspaceId, args);
      };
    };
  };

  /// Delete secret tool — requires secrets resource with write + user identity + workspaceId
  private func deleteSecretTool(
    map : SecretModel.SecretsState,
    uac : SlackAuthMiddleware.UserAuthContext,
    workspaceId : Nat,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_secret";
          description = ?"Removes a stored secret from the current workspace. Slack secrets require org-admin access. LLM API keys can be deleted by workspace admins.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"secretId\":{\"type\":\"string\",\"description\":\"Standard secret type: openRouterApiKey | anthropicApiKey | anthropicSetupToken | slackBotToken | slackSigningSecret. For custom keys use \'custom:<name>\' format.\"}},\"required\":[\"secretId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteSecretHandler.handle(map, uac, workspaceId, args);
      };
    };
  };

  // ============================================
  // EVENT STORE TOOL IMPLEMENTATIONS
  // ============================================

  /// Get event store stats tool — requires eventStore resource + user identity
  private func getEventStoreStatsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_event_store_stats";
          description = ?"Get event queue statistics: counts of unprocessed, processed, and failed events.";
          parameters = ?"{\"type\":\"object\",\"properties\":{}}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetEventStoreStatsHandler.handle(state, uac, args);
      };
    };
  };

  /// Get failed events tool — requires eventStore resource + user identity
  private func getFailedEventsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_failed_events";
          description = ?"List all failed events with their event IDs, error messages, and timestamps.";
          parameters = ?"{\"type\":\"object\",\"properties\":{}}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetFailedEventsHandler.handle(state, uac, args);
      };
    };
  };

  /// Delete failed events tool — requires eventStore resource with write + user identity
  private func deleteFailedEventsTool(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_failed_events";
          description = ?"Delete failed event(s). Provide eventId to delete one specific event, or omit to delete all failed events.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"eventId\":{\"type\":\"string\",\"description\":\"ID of a specific failed event to delete (e.g. 'slack_Ev0123'). Omit to delete all failed events.\"}}}";
        };
      };
      handler = func(args : Text) : async Text {
        await DeleteFailedEventsHandler.handle(state, uac, args);
      };
    };
  };

  /// Update session policy tool — requires sessionStores resource with write
  private func updateSessionPolicyTool(
    stores : SessionModel.SessionStores
  ) : FunctionTool {
    let summaryBudgetStr = Nat.toText(Constants.DEFAULT_SUMMARY_TOKEN_BUDGET);
    let maxTruncatedStr = Nat.toText(Constants.DEFAULT_MAX_TRUNCATED_TOKENS);
    let params = "{\"type\":\"object\",\"properties\":{\"agent_id\":{\"type\":\"number\",\"description\":\"The numeric ID of the agent whose session policy to update.\"},\"summary_token_budget\":{\"type\":\"number\",\"description\":\"Total token budget for session context (default " # summaryBudgetStr # "). Controls how much context window is reserved for session history.\"},\"max_truncated_tokens\":{\"type\":\"number\",\"description\":\"Cap per text field when truncating vertically (default " # maxTruncatedStr # "). Controls maximum tokens per individual field in truncated output.\"}},\"required\":[\"agent_id\"]}";
    {
      definition = {
        tool_type = "function";
        function = {
          name = "update_session_policy";
          description = ?"Update the session token-budget policy for a specific agent. Omit a field to keep its current value. Use this to tune how much context window budget is allocated to session summaries vs raw turns.";
          parameters = ?params;
        };
      };
      handler = func(args : Text) : async Text {
        await UpdateSessionPolicyHandler.handle(stores, args);
      };
    };
  };

  // ============================================
  // DISPATCH WORKFLOW TOOL IMPLEMENTATION
  // ============================================

  /// Dispatch workflow tool — requires engineDispatch + envelopeContext resources.
  private func dispatchWorkflowTool(
    engineDispatch : DispatchWorkflowHandler.EngineDispatch,
    envelopeContext : DispatchWorkflowHandler.EnvelopeContext,
    triggerMessageText : ?Text,
  ) : FunctionTool {
    {
      definition = {
        tool_type = DispatchWorkflowHandler.definition.tool_type;
        function = DispatchWorkflowHandler.definition.function;
      };
      handler = func(args : Text) : async Text {
        await DispatchWorkflowHandler.handle(engineDispatch, envelopeContext, triggerMessageText, args);
      };
    };
  };
};
