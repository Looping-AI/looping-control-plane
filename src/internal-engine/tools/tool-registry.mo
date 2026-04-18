import Array "mo:core/Array";
import List "mo:core/List";
import LlmWrapper "../wrappers/llm-wrapper";
import ToolTypes "./tool-types";
import ExecutionTypes "../execution-types";
import WorkspaceHandlers "../handlers/workspace-handlers";
import AgentHandlers "../handlers/agent-handlers";

module {

  // ── Types ──────────────────────────────────────────────────────────

  /// A function tool with its LLM-facing definition and handler implementation.
  public type FunctionTool = {
    definition : LlmWrapper.Tool;
    handler : ToolTypes.ToolHandler;
  };

  // ── Public API ─────────────────────────────────────────────────────

  /// Get all tools available for the given workflow and scope grants.
  public func getTools(
    workflowId : Text,
    scopeGrants : [ExecutionTypes.ScopeGrant],
  ) : [FunctionTool] {
    switch (workflowId) {
      case "admin-v1" { getAdminTools(scopeGrants) };
      case _ { [] };
    };
  };

  /// Get all tool definitions (for passing to LLM API).
  public func getDefinitions(
    workflowId : Text,
    scopeGrants : [ExecutionTypes.ScopeGrant],
  ) : [LlmWrapper.Tool] {
    Array.map<FunctionTool, LlmWrapper.Tool>(
      getTools(workflowId, scopeGrants),
      func(t : FunctionTool) : LlmWrapper.Tool { t.definition },
    );
  };

  /// Lookup a single tool by name.
  public func get(
    workflowId : Text,
    scopeGrants : [ExecutionTypes.ScopeGrant],
    name : Text,
  ) : ?FunctionTool {
    Array.find<FunctionTool>(
      getTools(workflowId, scopeGrants),
      func(t : FunctionTool) : Bool { t.definition.function_.name == name },
    );
  };

  // ── Admin workflow tools ───────────────────────────────────────────

  private func getAdminTools(
    grants : [ExecutionTypes.ScopeGrant]
  ) : [FunctionTool] {
    let tools = List.empty<FunctionTool>();

    // Echo — always available
    List.add(tools, echoTool());

    // Workspace tools — require workspace scope
    if (hasScope(grants, "workspace", #read)) {
      List.add(tools, listWorkspacesTool());
      if (hasScope(grants, "workspace", #write)) {
        List.add(tools, createWorkspaceTool());
        List.add(tools, deleteWorkspaceTool());
      };
    };

    // Agent tools — require agent scope
    if (hasScope(grants, "agent", #read)) {
      List.add(tools, listAgentsTool());
      List.add(tools, getAgentTool());
      if (hasScope(grants, "agent", #write)) {
        List.add(tools, registerAgentTool());
        List.add(tools, updateAgentTool());
      };
    };

    List.toArray(tools);
  };

  // ── Scope checking ─────────────────────────────────────────────────

  /// Check if any grant matches the requested domain and minimum access level.
  private func hasScope(
    grants : [ExecutionTypes.ScopeGrant],
    domain : Text,
    minAccess : ExecutionTypes.ScopeAccess,
  ) : Bool {
    Array.any<ExecutionTypes.ScopeGrant>(
      grants,
      func(g : ExecutionTypes.ScopeGrant) : Bool {
        switch (g, domain) {
          case (#workspace(w), "workspace") {
            accessSatisfies(w.access, minAccess);
          };
          case (#agent(a), "agent") { accessSatisfies(a.access, minAccess) };
          case _ { false };
        };
      },
    );
  };

  /// Check if `granted` access level satisfies `required` level.
  /// #write satisfies both #read and #write; #read only satisfies #read.
  private func accessSatisfies(
    granted : ExecutionTypes.ScopeAccess,
    required : ExecutionTypes.ScopeAccess,
  ) : Bool {
    switch (required) {
      case (#read) { true }; // both #read and #write satisfy #read
      case (#write) {
        switch (granted) {
          case (#write) { true };
          case (#read) { false };
        };
      };
    };
  };

  // ── Tool definitions ───────────────────────────────────────────────

  private func echoTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "echo";
          description = ?"Echoes back the input message. Useful for testing.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"The message to echo back\"}},\"required\":[\"message\"]}";
        };
      };
      handler = func(_callCore : ToolTypes.CallCore, args : Text) : async Text {
        args;
      };
    };
  };

  // ── Workspace tool definitions ─────────────────────────────────────

  private func listWorkspacesTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "list_workspaces";
          description = ?"Lists all workspace records including their IDs, names, and Slack admin channel anchors. Workspace 0 is the org workspace; its admin channel is also the org-admin channel.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = WorkspaceHandlers.listWorkspaces;
    };
  };

  private func createWorkspaceTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "create_workspace";
          description = ?"Creates a new workspace with the given name. Workspace names must be unique. Returns the new workspace ID.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name for the new workspace. Must be unique across all workspaces.\"}},\"required\":[\"name\"]}";
        };
      };
      handler = WorkspaceHandlers.createWorkspace;
    };
  };

  private func deleteWorkspaceTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "delete_workspace";
          description = ?"Permanently deletes a workspace by ID. This action is irreversible. Workspace 0 (the org workspace) is protected and cannot be deleted.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"workspaceId\":{\"type\":\"number\",\"description\":\"ID of the workspace to delete. Must be > 0.\"}},\"required\":[\"workspaceId\"]}";
        };
      };
      handler = WorkspaceHandlers.deleteWorkspace;
    };
  };

  // ── Agent tool definitions ─────────────────────────────────────────

  private func listAgentsTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "list_agents";
          description = ?"Lists all registered agents with their IDs, names, categories, LLM models, and configuration.";
          parameters = ?"{\"type\":\"object\",\"properties\":{},\"required\":[]}";
        };
      };
      handler = AgentHandlers.listAgents;
    };
  };

  private func getAgentTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "get_agent";
          description = ?"Looks up a registered agent by its numeric ID.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"Agent ID to look up.\"}},\"required\":[\"id\"]}";
        };
      };
      handler = AgentHandlers.getAgent;
    };
  };

  private func registerAgentTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "register_agent";
          description = ?"Registers a new custom agent. The name must be unique, lowercase, start with a letter, and contain only letters, digits, and hyphens.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Agent identifier (kebab-case, e.g. 'workspace-helper').\"},\"model\":{\"type\":\"string\",\"description\":\"OpenRouter model string (e.g. openai/gpt-oss-120b).\"},\"workspaceId\":{\"type\":\"number\",\"description\":\"Workspace that will own the agent.\"},\"allowedChannelIds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"description\":\"Slack channel IDs where this agent is permitted to run.\"}},\"required\":[\"name\",\"model\",\"workspaceId\",\"allowedChannelIds\"]}";
        };
      };
      handler = AgentHandlers.registerAgent;
    };
  };

  private func updateAgentTool() : FunctionTool {
    {
      definition = {
        tool_type = "function";
        function_ = {
          name = "update_agent";
          description = ?"Updates an existing agent's configuration. Provide the agent 'id' and only the fields you want to change; omitted fields are left unchanged.";
          parameters = ?"{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"number\",\"description\":\"ID of the agent to update.\"},\"name\":{\"type\":\"string\",\"description\":\"New agent name (optional).\"},\"model\":{\"type\":\"string\",\"description\":\"New OpenRouter model string (optional).\"}},\"required\":[\"id\"]}";
        };
      };
      handler = AgentHandlers.updateAgent;
    };
  };
};
