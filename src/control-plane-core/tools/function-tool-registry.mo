import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import ToolTypes "./tool-types";
import Constants "../constants";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import WorkspaceModel "../models/workspace-model";
import ListWorkspacesHandler "./handlers/workspaces/list-workspaces-handler";
import CreateWorkspaceHandler "./handlers/workspaces/create-workspace-handler";
import DeleteWorkspaceHandler "./handlers/workspaces/delete-workspace-handler";
import SetWorkspaceAdminChannelHandler "./handlers/workspaces/set-workspace-admin-channel-handler";
import WebSearchHandler "./handlers/web-search-handler";
import RegisterAgentHandler "./handlers/agents/register-agent-handler";
import ListAgentsHandler "./handlers/agents/list-agents-handler";
import GetAgentHandler "./handlers/agents/get-agent-handler";
import UpdateAgentHandler "./handlers/agents/update-agent-handler";
import UnregisterAgentHandler "./handlers/agents/unregister-agent-handler";
import StoreSecretHandler "./handlers/secrets/store-secret-handler";
import GetWorkspaceSecretsHandler "./handlers/secrets/get-workspace-secrets-handler";
import DeleteSecretHandler "./handlers/secrets/delete-secret-handler";
import GetEventStoreStatsHandler "./handlers/events/get-event-store-stats-handler";
import GetFailedEventsHandler "./handlers/events/get-failed-events-handler";
import DeleteFailedEventsHandler "./handlers/events/delete-failed-events-handler";
import SessionModel "../models/session-model";
import UpdateSessionPolicyHandler "./handlers/sessions/update-session-policy-handler";
import AgentModel "../models/agent-model";
import SecretModel "../models/secret-model";
import KeyDerivationService "../services/key-derivation-service";
import EventStoreModel "../models/event-store-model";

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
    // ECHO TOOL (for testing) - always available
    // ==========================================
    List.add(tools, echoTool());

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
    // WORKSPACE TOOLS - require workspaces resource
    // ==========================================
    switch (resources.workspaces) {
      case (?ws) {
        // Read tools — always available when resource is present
        List.add(tools, listWorkspacesTool(ws.state));
        // Write tools — require write=true AND a resolved user identity AND a platform secret resolver
        // (the resolver is needed for channel verification; the identity for authorization)
        switch (resources.userAuthContext, resources.resolveSlackBotToken) {
          case (?uac, ?resolver) {
            if (ws.write) {
              // These tools are always wired when workspace and credentials are present.
              List.add(tools, deleteWorkspaceTool(ws.state, uac, resources.triggerMessageText));
              List.add(tools, setWorkspaceAdminChannelTool(ws.state, uac, resolver));
              switch (resources.agentRegistry) {
                case (?ar) {
                  // create_workspace additionally requires agentRegistry;
                  List.add(tools, createWorkspaceTool(ws.state, uac, resolver, ar.state));
                };
                case (null) {};
              };
            };
          };
          case _ {};
        };
      };
      case (null) {};
    };

    // ==========================================
    // AGENT REGISTRY TOOLS - require agentRegistry resource
    // ==========================================
    switch (resources.agentRegistry) {
      case (?ar) {
        // Read tools — always available when resource is present
        List.add(tools, listAgentsTool(ar.state));
        List.add(tools, getAgentTool(ar.state));
        // Write tools — require write access and a resolved user identity
        switch (resources.userAuthContext) {
          case (?uac) {
            if (ar.write) {
              List.add(tools, registerAgentTool(ar.state, uac, resources.resolveSlackBotToken));
              List.add(tools, updateAgentTool(ar.state, uac));
              List.add(tools, unregisterAgentTool(ar.state, uac));
            };
          };
          case (null) {};
        };
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

  // ============================================
  // PRIVATE TOOL IMPLEMENTATIONS
  // ============================================

  /// Echo tool - no resources required
  private func echoTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "echo";
          description = ?"Echoes back the input message. Useful for testing.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"The message to echo back\"}},\"required\":[\"message\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        // Simply return the arguments as-is
        args;
      };
    };
  };

  // ============================================
  // WORKSPACE TOOL IMPLEMENTATIONS
  // ============================================

  /// List workspaces tool — always available when workspaces resource is present
  private func listWorkspacesTool(state : WorkspaceModel.WorkspacesState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_workspaces";
          description = ?"Lists all workspace records including their IDs, names, and Slack admin channel anchors. Workspace 0 is the org workspace; its admin channel is also the org-admin channel.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListWorkspacesHandler.handle(state, args);
      };
    };
  };

  /// Create workspace tool — requires workspaces resource with write
  private func createWorkspaceTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    resolver : Text -> ?Text,
    agentRegistry : AgentModel.AgentRegistryState,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "create_workspace";
          description = ?"Creates a new workspace with the given name and anchors a Slack channel as its admin channel. Workspace names must be unique. The channelId must exist and the bot must be invited to it. Returns the new workspace ID.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name for the new workspace. Must be unique across all workspaces.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Slack channel ID (e.g. 'C01234567') to set as the admin channel for the new workspace. The bot must be invited to this channel.\"}},\"required\":[\"name\",\"channelId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await CreateWorkspaceHandler.handle(state, agentRegistry, uac, resolver, args);
      };
    };
  };

  /// Delete workspace tool — requires workspaces resource with write
  private func deleteWorkspaceTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    triggerMessageText : ?Text,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "delete_workspace";
          description = ?"Permanently deletes a workspace by ID. This action is irreversible. Workspace 0 (the org workspace) is protected and cannot be deleted.\n\nThis operation requires explicit user confirmation. The user's Slack message MUST contain exactly '::admin <workspace name>' (e.g. '::admin Marketing') as the full message text — nothing more. The system validates the user's actual message automatically; you cannot provide the phrase yourself. Look up the workspace name first if needed, then instruct the user to type that exact phrase as their next message. Only call this tool after the user has sent that confirmation message.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to delete. Must be > 0.\"}},\"required\":[\"workspaceId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        DeleteWorkspaceHandler.handle(state, uac, triggerMessageText, args);
      };
    };
  };

  /// Set workspace admin channel tool — requires workspaces resource with write
  private func setWorkspaceAdminChannelTool(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    resolver : Text -> ?Text,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "set_workspace_admin_channel";
          description = ?"Sets the Slack channel whose members become admins of the given workspace. For workspace 0 (the org workspace) this also anchors the org-admin channel. Channel IDs must be globally unique across all workspace anchors.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to configure.\"},\"channelId\":{\"type\":\"string\",\"description\":\"Slack channel ID (e.g. 'C01234567') to set as the admin channel.\"}},\"required\":[\"workspaceId\",\"channelId\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await SetWorkspaceAdminChannelHandler.handle(state, uac, resolver, args);
      };
    };
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
  // AGENT REGISTRY TOOL IMPLEMENTATIONS
  // ============================================

  /// List agents tool — always available when agentRegistry resource is present
  private func listAgentsTool(state : AgentModel.AgentRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "list_agents";
          description = ?"Lists all registered agents with their IDs, names, categories, LLM models, and configuration.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await ListAgentsHandler.handle(state, args);
      };
    };
  };

  /// Get agent tool — always available when agentRegistry resource is present
  private func getAgentTool(state : AgentModel.AgentRegistryState) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "get_agent";
          description = ?"Looks up a registered agent by its ID (number) or name (string). Provide either 'id' or 'name'.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"Agent ID to look up.\"},\"name\":{\"type\":\"string\",\"description\":\"Agent name to look up (case-insensitive).\"}},\"required\":[]}";
        };
      };
      handler = func(args : Text) : async Text {
        await GetAgentHandler.handle(state, args);
      };
    };
  };

  /// Register agent tool — requires agentRegistry resource with write + user identity
  private func registerAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    resolveSlackBotToken : ?(Text -> ?Text),
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "register_agent";
          description = ?"Registers a new custom agent in the global registry. The name must be unique, lowercase, start with a letter, and contain only letters, digits, and hyphens. executionEngines specifies which execution backends the agent may use (at least one required): api = in-canister LLM loop via OpenRouter; canister = external canister called via envelope/webhook; github = GitHub Actions workflow triggered via webhook reply.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Agent identifier (kebab-case, e.g. 'workspace-helper').\"},\"executionEngines\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"api\",\"canister\",\"github\"]},\"minItems\":1,\"description\":\"Execution backends this agent is permitted to use.\"},\"ownedBy\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Workspace that will own the agent. Omit to default to org workspace (0).\"},\"model\":{\"type\":\"string\",\"description\":\"OpenRouter model string (e.g. openai/gpt-oss-120b). Defaults to openai/gpt-oss-120b if omitted.\"},\"allowedChannelIds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"description\":\"Slack channel IDs where this agent is permitted to run. Required; must contain at least one channel ID.\"},\"secretsAllowed\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\"},\"secretId\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"anthropicApiKey\",\"anthropicSetupToken\"]},{\"type\":\"string\",\"pattern\":\"^custom:.+\",\"description\":\"Custom secret identifier, e.g. custom:my-key\"}]}},\"required\":[\"workspaceId\",\"secretId\"]},\"description\":\"Secrets this agent may access. Omit for empty list.\"},\"secretOverrides\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"secretId\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"anthropicApiKey\",\"anthropicSetupToken\"]},{\"type\":\"string\",\"pattern\":\"^custom:.+\",\"description\":\"Custom secret identifier, e.g. custom:my-key\"}]},\"customKeyName\":{\"type\":\"string\",\"description\":\"Name of the custom secret (without the 'custom:' prefix).\"}},\"required\":[\"secretId\",\"customKeyName\"]},\"description\":\"Per-agent credential overrides. For each entry, resolving secretId first looks up custom:<customKeyName> in the agent's workspace. Omit for none.\"}},\"required\":[\"name\",\"executionEngines\",\"allowedChannelIds\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await RegisterAgentHandler.handle(state, uac, args, ?OpenRouterWrapper.validateModel, resolveSlackBotToken);
      };
    };
  };

  /// Update agent tool — requires agentRegistry resource with write + user identity
  private func updateAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "update_agent";
          description = ?"Updates an existing agent's configuration. Provide the agent 'id' and only the fields you want to change; omitted fields are left unchanged.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to update.\"},\"name\":{\"type\":\"string\",\"description\":\"New agent name (optional).\"},\"executionEngines\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"api\",\"canister\",\"github\"]},\"minItems\":1,\"description\":\"Replace the full execution engines list (optional). Must be non-empty.\"},\"model\":{\"type\":\"string\",\"description\":\"New OpenRouter model string (optional).\"},\"allowedChannelIds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"description\":\"Replace the full channel allowlist (optional). Must be non-empty \\u2014 the allowlist cannot be emptied.\"},\"secretsAllowed\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\"},\"secretId\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"anthropicApiKey\",\"anthropicSetupToken\"]},{\"type\":\"string\",\"pattern\":\"^custom:.+\",\"description\":\"Custom secret identifier, e.g. custom:my-key\"}]}},\"required\":[\"workspaceId\",\"secretId\"]},\"description\":\"Replace the full secrets whitelist (optional). Pass [] to revoke all secret access.\"},\"secretOverrides\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"secretId\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"openRouterApiKey\",\"anthropicApiKey\",\"anthropicSetupToken\"]},{\"type\":\"string\",\"pattern\":\"^custom:.+\",\"description\":\"Custom secret identifier, e.g. custom:my-key\"}]},\"customKeyName\":{\"type\":\"string\"}},\"required\":[\"secretId\",\"customKeyName\"]},\"description\":\"Replace per-agent credential overrides (optional). Pass [] to clear all overrides.\"}},\"required\":[\"id\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UpdateAgentHandler.handle(state, uac, args, ?OpenRouterWrapper.validateModel);
      };
    };
  };

  /// Unregister agent tool — requires agentRegistry resource with write + user identity
  private func unregisterAgentTool(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
  ) : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function = {
          name = "unregister_agent";
          description = ?"Permanently removes an agent from the registry. This action cannot be undone. Any active sessions referencing this agent will fail after removal.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to unregister.\"}},\"required\":[\"id\"]}";
        };
      };
      handler = func(args : Text) : async Text {
        await UnregisterAgentHandler.handle(state, uac, args);
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
};
