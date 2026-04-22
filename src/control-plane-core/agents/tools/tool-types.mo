import AgentModel "../../models/agent-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import SecretModel "../../models/secret-model";
import KeyDerivationService "../../services/key-derivation-service";
import ExecutionEnvelopeModel "../../models/execution-envelope-model";
import ExecutionTypes "../../types/execution";
import InternalEngine "../../../internal-engine/main";

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
    // Used by destructive operations to verify explicit user confirmation.
    triggerMessageText : ?Text;

    // Secrets store - if provided, secrets-management tools are available.
    // write=true enables store_secret and delete_secret.
    // All secrets tools also require workspaceId and userAuthContext.
    secrets : ?{
      state : SecretModel.SecretsState;
      keyCache : KeyDerivationService.KeyCache;
      write : Bool;
    };

    // Engine dispatch resources — if provided, dispatch_workflow tool is available.
    // Carries the envelope state (token store + counter + salt) and the pre-resolved engine actor.
    engineDispatch : ?{
      envelopeState : ExecutionEnvelopeModel.EnvelopeState;
      internalEngine : InternalEngine.InternalEngine;
    };

    // Per-turn envelope context needed by dispatch_workflow to build the ExecutionEnvelope.
    // Requires engineDispatch to also be set.
    envelopeContext : ?{
      agent : AgentModel.AgentRecord;
      turnId : Text;
      instructions : Text;
      messages : [ExecutionTypes.ChatMessage];
      botToken : ?Text;
      apiKey : Text;
    };
  };
};
