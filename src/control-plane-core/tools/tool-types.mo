import Map "mo:core/Map";
import OpenRouterWrapper "../wrappers/openrouter-wrapper";
import ValueStreamModel "../models/value-stream-model";
import MetricModel "../models/metric-model";
import ObjectiveModel "../models/objective-model";
import WorkspaceModel "../models/workspace-model";
import AgentModel "../models/agent-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import SecretModel "../models/secret-model";
import KeyDerivationService "../services/key-derivation-service";
import EventStoreModel "../models/event-store-model";

module {
  // ============================================
  // Shared Tool Types
  // ============================================

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
  };

  /// Outcome of a tool call execution
  public type ToolCallOutcome = {
    #success : Text; // JSON string result
    #error : Text; // Error message
  };

  // ============================================
  // Function Tool Resources
  // ============================================

  /// Resources that can be provided to function tools.
  /// Each resource is optional - tools requiring unavailable resources are excluded.
  /// This creates a natural allowlist mechanism controlled by the caller.
  public type ToolResources = {
    // Current workspace context
    workspaceId : ?Nat;

    // OpenRouter API key - required for web search and other OpenRouter-powered tools
    openRouterApiKey : ?Text;

    // Slack bot token - required for channel verification in workspace anchor tools
    slackBotToken : ?Text;

    // Slack user identity of the user who triggered this agent turn.
    // Required for authorization checks in workspace-management write tools.
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;

    // Value Streams - if provided with write=true, save_value_stream tool is available
    valueStreams : ?{
      map : ValueStreamModel.ValueStreamsMap;
      write : Bool; // false = read-only (future: could enable a "get_value_streams" tool)
    };

    // Metrics - if provided with write=true, metric management tools are available
    metrics : ?{
      registryState : MetricModel.MetricsRegistryState;
      datapoints : MetricModel.MetricDatapointsStore;
      write : Bool; // false = read-only (future: could enable read-only metric tools)
    };

    // Objectives - if provided with write=true, objective management tools are available
    objectives : ?{
      map : ObjectiveModel.WorkspaceObjectivesMap;
      write : Bool; // false = read-only (future: could enable read-only objective tools)
    };

    // Workspaces - if provided, workspace-management tools are available.
    // write=true enables create_workspace, set_workspace_admin_channel, set_workspace_member_channel.
    workspaces : ?{
      state : WorkspaceModel.WorkspacesState;
      write : Bool;
    };

    // Agent Registry - if provided, agent-management tools are available.
    // write=true enables register_agent, update_agent, unregister_agent.
    agentRegistry : ?{
      state : AgentModel.AgentRegistryState;
      write : Bool;
    };

    // MCP Tool Registry - if provided, MCP tool management tools are available.
    // write=true enables register_mcp_tool, unregister_mcp_tool.
    mcpToolRegistry : ?{
      state : Map.Map<Text, McpToolRegistration>;
      write : Bool;
    };

    // Secrets store - if provided, secrets-management tools are available.
    // write=true enables store_secret and delete_secret.
    // store_secret additionally requires the workspaces resource to validate workspace existence.
    secrets : ?{
      state : SecretModel.SecretsState;
      keyCache : KeyDerivationService.KeyCache;
      write : Bool;
    };

    // Event store - if provided, event queue management tools are available.
    // write=true enables delete_failed_events.
    eventStore : ?{
      state : EventStoreModel.EventStoreState;
      write : Bool;
    };
  };

  // ============================================
  // MCP Tool Types
  // ============================================

  /// MCP tool registration - stored in state, runtime configurable
  public type McpToolRegistration = {
    definition : OpenRouterWrapper.Tool;
    serverId : Text; // Reference to MCP server config
    remoteName : ?Text; // Tool name on server (if different from definition.function.name)
  };

  /// MCP server configuration
  public type McpServerConfig = {
    id : Text;
    endpoint : Text;
    // Future: auth config, headers, etc.
  };
};
