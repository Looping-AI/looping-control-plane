import Array "mo:core/Array";
import Text "mo:core/Text";
import Json "mo:json";
import { str; obj; arr } "mo:json";
import Hashing "./hashing";

/// Workflow catalog — the engine's source of truth for available workflows.
///
/// ─ Authoring rules ──────────────────────────────────────────────────────────
///  • Keep `allDescriptors` in strict alphabetical order by `workflowName`.
///  • Use resource-prefix naming: agents_, session_, slack_queue_, workspace_.
///  • Do NOT reorder entries — catalog hash stability depends on declaration order.
/// ────────────────────────────────────────────────────────────────────────────
module {

  // ── Types ──────────────────────────────────────────────────────────

  /// A single pre-validation rule applied to a named argument before dispatch.
  /// Recognized rules today: "slack_channel_exists".
  /// Unknown rules will cause Core to return an error at dispatch time (Phase 3).
  public type PreValidationRule = {
    param : Text;
    rule : Text;
  };

  /// A directive Core must act on before dispatching this workflow.
  ///
  /// #require_("approval") — suspend the turn and prompt the user for confirmation.
  /// #preValidation(rules) — validate one or more args against external systems before dispatch.
  ///
  /// Unknown variants received from a future engine version are ignored by Core (forward compat).
  public type CoreDirective = {
    #require_ : Text;
    #preValidation : [PreValidationRule];
  };

  public type RequiredScope = {
    scope : Text;
    access : Text;
  };

  public type WorkflowDescriptor = {
    workflowName : Text;
    description : Text;
    /// Raw JSON schema string — passed directly to the LLM tool definition.
    parametersJsonSchema : Text;
    requiredScopes : [RequiredScope];
    coreDirectives : [CoreDirective];
  };

  // ── Descriptor catalog ─────────────────────────────────────────────

  public let allDescriptors : [WorkflowDescriptor] = [
    {
      workflowName = "agents_get";
      description = "Looks up a registered agent by its numeric ID.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"Agent ID to look up.\"}},\"required\":[\"id\"]}";
      requiredScopes = [{ scope = "agents"; access = "read" }];
      coreDirectives = [];
    },
    {
      workflowName = "agents_list";
      description = "Lists all registered agents with their IDs, names, categories, LLM models, and configuration.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";
      requiredScopes = [{ scope = "agents"; access = "read" }];
      coreDirectives = [];
    },
    {
      workflowName = "agents_register";
      description = "Registers a new custom agent in the current workspace. The name must be unique, lowercase, start with a letter, and contain only letters, digits, and hyphens.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Agent identifier (kebab-case, e.g. 'workspace-helper').\"},\"model\":{\"type\":\"string\",\"description\":\"OpenRouter model string (e.g. openai/gpt-oss-120b).\"},\"allowedChannelIds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"description\":\"Slack channel IDs where this agent is permitted to run.\"},\"executionEngines\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"canister\",\"github\"]},\"description\":\"Execution engine(s) this agent may use. Defaults to [] (none) if omitted.\"}},\"required\":[\"name\",\"model\",\"allowedChannelIds\"]}";
      requiredScopes = [{ scope = "agents"; access = "write" }];
      coreDirectives = [];
    },
    {
      workflowName = "agents_unregister";
      description = "Permanently removes an agent by ID. The agent must belong to the current workspace.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to unregister.\"}},\"required\":[\"id\"]}";
      requiredScopes = [{ scope = "agents"; access = "write" }];
      coreDirectives = [];
    },
    {
      workflowName = "agents_update";
      description = "Updates an existing agent's configuration. Provide the agent 'id' and only the fields you want to change; omitted fields are left unchanged.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to update.\"},\"name\":{\"type\":\"string\",\"description\":\"New agent name (optional).\"},\"model\":{\"type\":\"string\",\"description\":\"New OpenRouter model string (optional).\"},\"executionEngines\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"canister\",\"github\"]},\"description\":\"New execution engines (optional). Omit to leave unchanged.\"}},\"required\":[\"id\"]}";
      requiredScopes = [{ scope = "agents"; access = "write" }];
      coreDirectives = [];
    },
    {
      workflowName = "session_update_policy";
      description = "Updates the session context policy for an agent. Controls how much conversation history is kept and summarized.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"agentId\":{\"type\":\"number\",\"description\":\"ID of the agent whose session policy to update.\"},\"summaryTokenBudget\":{\"type\":\"number\",\"description\":\"Maximum tokens for conversation summary.\"},\"maxTruncatedTokens\":{\"type\":\"number\",\"description\":\"Maximum tokens for truncated recent messages.\"}},\"required\":[\"agentId\",\"summaryTokenBudget\",\"maxTruncatedTokens\"]}";
      requiredScopes = [{ scope = "session"; access = "write" }];
      coreDirectives = [];
    },
    {
      workflowName = "slack_queue_failed";
      description = "Lists all failed Slack queue events with their event IDs and error messages.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";
      requiredScopes = [{ scope = "slackQueue"; access = "read" }];
      coreDirectives = [];
    },
    {
      workflowName = "slack_queue_stats";
      description = "Returns Slack queue statistics: counts of unprocessed, processed, and failed events.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";
      requiredScopes = [{ scope = "slackQueue"; access = "read" }];
      coreDirectives = [];
    },
    {
      workflowName = "workspace_create";
      description = "Creates a new workspace with the given name. Workspace names must be unique. Returns the new workspace ID.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name for the new workspace. Must be unique across all workspaces.\"}},\"required\":[\"name\"]}";
      requiredScopes = [{ scope = "workspace"; access = "write" }];
      coreDirectives = [];
    },
    {
      workflowName = "workspace_delete";
      description = "Permanently deletes a workspace by ID. This action is irreversible. Workspace 0 (the org workspace) is protected and cannot be deleted.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to delete. Must be > 0.\"}},\"required\":[\"workspaceId\"]}";
      requiredScopes = [{ scope = "workspace"; access = "write" }];
      coreDirectives = [#require_("approval")];
    },
    {
      workflowName = "workspace_get";
      description = "Returns the current workspace record including its ID, name, and Slack admin channel anchor.";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";
      requiredScopes = [{ scope = "workspace"; access = "read" }];
      coreDirectives = [];
    },
    {
      workflowName = "workspace_set_admin_channel";
      description = "Sets the Slack admin channel for the current workspace. The channelId must be a valid Slack channel ID (e.g. C012345).";
      parametersJsonSchema = "{\"type\":\"object\",\"properties\":{\"channelId\":{\"type\":\"string\",\"description\":\"Slack channel ID to set as the admin channel.\"}},\"required\":[\"channelId\"]}";
      requiredScopes = [{ scope = "workspace"; access = "write" }];
      coreDirectives = [
        #preValidation([{ param = "channelId"; rule = "slack_channel_exists" }])
      ];
    },
  ];

  // ── JSON serialization ─────────────────────────────────────────────

  private func directiveToJson(d : CoreDirective) : Json.Json {
    switch (d) {
      case (#require_(val)) {
        obj([("require", str(val))]);
      };
      case (#preValidation(rules)) {
        obj([(
          "preValidation",
          arr(
            Array.map<PreValidationRule, Json.Json>(
              rules,
              func(r : PreValidationRule) : Json.Json {
                obj([("param", str(r.param)), ("rule", str(r.rule))]);
              },
            )
          ),
        )]);
      };
    };
  };

  private func scopeToJson(s : RequiredScope) : Json.Json {
    // Field order: access, scope (alphabetical)
    obj([("access", str(s.access)), ("scope", str(s.scope))]);
  };

  private func descriptorToJson(d : WorkflowDescriptor) : Json.Json {
    // Field order: coreDirectives, description, parametersJsonSchema, requiredScopes, workflowName (alphabetical)
    obj([
      (
        "coreDirectives",
        arr(Array.map<CoreDirective, Json.Json>(d.coreDirectives, directiveToJson)),
      ),
      ("description", str(d.description)),
      // parametersJsonSchema is a raw JSON string; str() encodes it as a JSON string value.
      ("parametersJsonSchema", str(d.parametersJsonSchema)),
      (
        "requiredScopes",
        arr(Array.map<RequiredScope, Json.Json>(d.requiredScopes, scopeToJson)),
      ),
      ("workflowName", str(d.workflowName)),
    ]);
  };

  /// Serialize descriptors to a canonical JSON array.
  /// Insertion order is the canonical order — do not sort at runtime.
  public func toCanonicalJson(descriptors : [WorkflowDescriptor]) : Text {
    Json.stringify(
      arr(Array.map<WorkflowDescriptor, Json.Json>(descriptors, descriptorToJson)),
      null,
    );
  };

  // ── Hashing ────────────────────────────────────────────────────────

  /// Compute a stable SHA-256 hash of the canonical JSON representation.
  /// Returns a 64-character lowercase hex string.
  /// Hash stability relies on `allDescriptors` declaration order — do not reorder entries.
  public func computeHash(descriptors : [WorkflowDescriptor]) : Text {
    Hashing.sha256Hex(toCanonicalJson(descriptors));
  };

  // ── Wire format ────────────────────────────────────────────────────

  /// Returns the full catalog JSON payload for `listWorkflows()`.
  /// Format: {"catalogHash":"<64-char hex>","descriptors":[...]}
  public func listWorkflowsJson(hash : Text) : Text {
    Json.stringify(
      obj([
        ("catalogHash", str(hash)),
        ("descriptors", arr(Array.map<WorkflowDescriptor, Json.Json>(allDescriptors, descriptorToJson))),
      ]),
      null,
    );
  };

};
