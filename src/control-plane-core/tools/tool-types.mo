import WorkspaceModel "../models/workspace-model";
import AgentModel "../models/agent-model";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";
import SecretModel "../models/secret-model";
import KeyDerivationService "../services/key-derivation-service";
import EventStoreModel "../models/event-store-model";
import SessionModel "../models/session-model";

module {
  // ============================================
  // Shared Tool Types
  // ============================================

  /// Result from executing a single tool call
  public type ToolResult = {
    callId : Text;
    result : ToolCallOutcome;
    durationMs : Nat;
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

    // Slack bot token resolver — returns the decrypted Slack bot token for the org.
    // Takes an operation name for audit logging.
    // Only admin-category agents receive a resolver closure; all others get null.
    // Tools call this on-demand rather than receiving pre-fetched tokens.
    resolveSlackBotToken : ?(Text -> ?Text);

    // Slack user identity of the user who triggered this agent turn.
    // Required for authorization checks in workspace-management write tools.
    userAuthContext : ?SlackAuthMiddleware.UserAuthContext;

    // The verbatim text of the Slack message that triggered this agent turn.
    // Set by the agent from channel history before building ToolResources.
    // Used by destructive operations (e.g. delete_workspace) to verify that the
    // user explicitly typed a confirmation phrase in their own message, making it
    // impossible for the LLM to fabricate a confirmation.
    triggerMessageText : ?Text;

    // Workspaces - if provided, workspace-management tools are available.
    // write=true enables create_workspace, set_workspace_admin_channel.
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

    // Secrets store - if provided, secrets-management tools are available.
    // write=true enables store_secret and delete_secret.
    // All secrets tools also require workspaceId and userAuthContext.
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

    // Session stores - if provided, session policy management tools are available.
    // write=true enables update_session_policy.
    sessionStores : ?{
      stores : SessionModel.SessionStores;
      write : Bool;
    };
  };
};
