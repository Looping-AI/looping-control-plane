import { test; suite; expect } "mo:test";
import Int "mo:core/Int";
import Json "mo:json";
import Nat "mo:core/Nat";
import Set "mo:core/Set";
import Text "mo:core/Text";
import WorkflowApiService "../../../../src/control-plane-core/services/workflow-api-service";
import WorkflowEnvelopeModel "../../../../src/control-plane-core/models/workflow-envelope-model";
import WorkflowTypes "../../../../src/control-plane-core/types/workflow";
import WorkspaceModel "../../../../src/control-plane-core/models/workspace-model";
import AgentModel "../../../../src/control-plane-core/models/agent-model";
import ApprovalModel "../../../../src/control-plane-core/models/approval-model";
import EventStoreModel "../../../../src/control-plane-core/models/event-store-model";
import SessionModel "../../../../src/control-plane-core/models/session-model";

// ============================================
// Shared test fixtures
// ============================================

/// One channel so #custom agents pass the non-empty check.
let oneChannel : Set.Set<Text> = Set.fromArray(["C_GENERAL"], Text.compare);

/// A minimal #custom AgentConfig with a valid channel.
let customCfg : AgentModel.AgentConfig = {
  name = "bot";
  model = "gpt-4";
  workflowEngines = [#canister];
  allowedChannelIds = oneChannel;
  secrets = { allowed = []; overrides = [] };
};

/// Pre-seeded workspaces: ws 0 ("Default") + ws 1 ("Workspace One").
func freshWorkspaces() : WorkspaceModel.WorkspacesState {
  let ws = WorkspaceModel.emptyState();
  ignore WorkspaceModel.createWorkspace(ws, "Workspace One"); // id = 1
  ws;
};

/// Build ServiceDeps from loose components.
func mkDeps(
  store : WorkflowEnvelopeModel.EnvelopeState,
  ws : WorkspaceModel.WorkspacesState,
  agents : AgentModel.AgentRegistryState,
) : WorkflowApiService.ServiceDeps {
  {
    envelopeState = store;
    workspaces = ws;
    agentRegistry = agents;
    approvalState = ApprovalModel.emptyState();
    eventStore = EventStoreModel.empty();
    sessionStores = SessionModel.emptyStores();
  };
};

/// Build a fresh Service from loose components.
func mkSvc(
  store : WorkflowEnvelopeModel.EnvelopeState,
  ws : WorkspaceModel.WorkspacesState,
  agents : AgentModel.AgentRegistryState,
) : WorkflowApiService.Service {
  WorkflowApiService.Service(mkDeps(store, ws, agents));
};

/// Issue a token and return (store, ws, agents, svc, nonce).
func issue(
  grants : [WorkflowTypes.ScopeGrant],
  wsId : Nat,
) : (WorkflowEnvelopeModel.EnvelopeState, WorkspaceModel.WorkspacesState, AgentModel.AgentRegistryState, WorkflowApiService.Service, Text) {
  let store = WorkflowEnvelopeModel.emptyState();
  let ws = freshWorkspaces();
  let agents = AgentModel.emptyState();
  let nonce = WorkflowEnvelopeModel.issue(store, "1_0", wsId, grants).nonce;
  let svc = mkSvc(store, ws, agents);
  (store, ws, agents, svc, nonce);
};

/// Returns true when the HandleResult response is #ok.
func isOk(r : WorkflowTypes.HandleResult) : Bool {
  switch (r.response) { case (#ok(_)) { true }; case (#err(_)) { false } };
};

func isErr(r : WorkflowTypes.HandleResult) : Bool { not isOk(r) };

/// Extracts the `type` field from a HandleResult #err JSON body.
/// Returns empty string if the result is not an error or the body cannot be parsed.
func errType(r : WorkflowTypes.HandleResult) : Text {
  switch (r.response) {
    case (#ok(_)) { "" };
    case (#err(body)) {
      switch (Json.parse(body)) {
        case (#err(_)) { "" };
        case (#ok(parsed)) {
          switch (Json.get(parsed, "type")) {
            case (?#string(t)) { t };
            case (_) { "" };
          };
        };
      };
    };
  };
};

// ============================================
// Auth guard — invalid / missing token
// ============================================

suite(
  "auth guard — invalid / missing token",
  func() {
    test(
      "GET /workspace with unknown nonce returns error",
      func() {
        let svc = mkSvc(WorkflowEnvelopeModel.emptyState(), freshWorkspaces(), AgentModel.emptyState());
        let r = svc.handleRequest(#get, "/workspace", "{\"envelopeNonce\":\"ghost\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "POST /workspace with missing envelopeNonce returns error",
      func() {
        let svc = mkSvc(WorkflowEnvelopeModel.emptyState(), freshWorkspaces(), AgentModel.emptyState());
        let r = svc.handleRequest(#post, "/workspace", "{}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "invalid JSON body returns error",
      func() {
        let svc = mkSvc(WorkflowEnvelopeModel.emptyState(), freshWorkspaces(), AgentModel.emptyState());
        let r = svc.handleRequest(#get, "/workspace", "not-json");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "unknown path returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#get, "/does-not-exist", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// GET /workspace
// ============================================

suite(
  "GET /workspace",
  func() {
    test(
      "returns workspace data for a valid read token (ws 0)",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 0);
        let r = svc.handleRequest(#get, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "returns workspace data for a valid read token (ws 1)",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#get, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "write token also covers read (coversAccess rule)",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#get, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "wrong scope (#agents) is rejected",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #read })], 0);
        let r = svc.handleRequest(#get, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /workspace — create
// ============================================

suite(
  "POST /workspace — create",
  func() {
    test(
      "org admin (ws 0) with write scope can create a workspace",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#post, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"New WS\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "non-org-admin (ws 1) cannot create a workspace",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"New WS\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "read-only token cannot create a workspace",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 0);
        let r = svc.handleRequest(#post, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"New WS\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "missing name field returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#post, "/workspace", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /workspace/update — rename
// ============================================

suite(
  "POST /workspace/update — rename",
  func() {
    test(
      "write token can rename own workspace (ws 1)",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/workspace/update", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"Renamed\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "read-only token cannot rename",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workspace/update", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"Renamed\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "missing name field returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/workspace/update", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// DELETE /workspace/{id}
// ============================================

suite(
  "DELETE /workspace/{id}",
  func() {
    test(
      "org admin + write scope + approved code can delete ws 1",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let approvalState = ApprovalModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 0, [#workspace({ access = #write })]).nonce;
        let code = ApprovalModel.request(approvalState, "workspace_delete", "{}", 1, 0, "turn_1", "U_ADMIN");
        ignore ApprovalModel.approve(approvalState, code, "U_ADMIN", Set.empty());
        let svc = WorkflowApiService.Service({
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState;
          eventStore = EventStoreModel.empty();
          sessionStores = SessionModel.emptyStores();
        });
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"" # code # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "missing approvalCode is rejected with approvalRequired",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalRequired");
      },
    );

    test(
      "unknown approvalCode is rejected with approvalInvalid",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"nonexistent\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalInvalid");
      },
    );

    test(
      "pending approvalCode is rejected with approvalInvalid",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let approvalState = ApprovalModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 0, [#workspace({ access = #write })]).nonce;
        let code = ApprovalModel.request(approvalState, "workspace_delete", "{}", 1, 0, "turn_1", "U_ADMIN");
        // code remains #pending — not approved
        let svc = WorkflowApiService.Service({
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState;
          eventStore = EventStoreModel.empty();
          sessionStores = SessionModel.emptyStores();
        });
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"" # code # "\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalInvalid");
      },
    );

    test(
      "denied approvalCode is rejected with approvalInvalid",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let approvalState = ApprovalModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 0, [#workspace({ access = #write })]).nonce;
        let code = ApprovalModel.request(approvalState, "workspace_delete", "{}", 1, 0, "turn_1", "U_ADMIN");
        switch (ApprovalModel.deny(approvalState, code, "U_ADMIN", Set.fromArray([0], Nat.compare))) {
          case (#ok(_)) {};
          case (#err(_)) { assert false };
        };
        let svc = WorkflowApiService.Service({
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState;
          eventStore = EventStoreModel.empty();
          sessionStores = SessionModel.emptyStores();
        });
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"" # code # "\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalInvalid");
      },
    );

    test(
      "approvalCode for wrong workspaceId is rejected with approvalMismatch",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let approvalState = ApprovalModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 0, [#workspace({ access = #write })]).nonce;
        // Code is for workspace 99, not workspace 1
        let code = ApprovalModel.request(approvalState, "workspace_delete", "{}", 99, 0, "turn_1", "U_ADMIN");
        ignore ApprovalModel.approve(approvalState, code, "U_ADMIN", Set.empty());
        let svc = WorkflowApiService.Service({
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState;
          eventStore = EventStoreModel.empty();
          sessionStores = SessionModel.emptyStores();
        });
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"" # code # "\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalMismatch");
      },
    );

    test(
      "approvalCode for wrong workflowName is rejected with approvalMismatch",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let approvalState = ApprovalModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 0, [#workspace({ access = #write })]).nonce;
        // Code is for a different workflow
        let code = ApprovalModel.request(approvalState, "other_workflow", "{}", 1, 0, "turn_1", "U_ADMIN");
        ignore ApprovalModel.approve(approvalState, code, "U_ADMIN", Set.empty());
        let svc = WorkflowApiService.Service({
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState;
          eventStore = EventStoreModel.empty();
          sessionStores = SessionModel.emptyStores();
        });
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\",\"approvalCode\":\"" # code # "\"}");
        expect.bool(isErr(r)).isTrue();
        expect.text(errType(r)).equal("approvalMismatch");
      },
    );

    test(
      "non-org-admin token (ws 1) cannot delete",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#delete, "/workspace/1", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "non-numeric workspace id returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 0);
        let r = svc.handleRequest(#delete, "/workspace/abc", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /workspace/admin-channel
// ============================================

suite(
  "POST /workspace/admin-channel",
  func() {
    test(
      "write scope sets admin channel",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/workspace/admin-channel", "{\"envelopeNonce\":\"" # nonce # "\",\"channelId\":\"C_ADMIN\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "read-only token cannot set admin channel",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workspace/admin-channel", "{\"envelopeNonce\":\"" # nonce # "\",\"channelId\":\"C_ADMIN\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// GET /agent — list
// ============================================

suite(
  "GET /agent — list",
  func() {
    test(
      "agents:read token returns ok (empty list) when no agents registered",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #read })], 1);
        let r = svc.handleRequest(#get, "/agent", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "agents:write token also covers agents:read",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#get, "/agent", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "wrong scope (#workspace) is rejected for GET /agent",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#get, "/agent", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /agent — create
// ============================================

suite(
  "POST /agent — create",
  func() {
    test(
      "agents:write token can create a custom agent",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"bot\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"]}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "agents:read token cannot create an agent",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"bot\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"]}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "missing name field returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"]}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "creates agent with explicit workflowEngines [canister]",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"bot\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"],\"workflowEngines\":[\"canister\"]}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "creates agent with empty workflowEngines []",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"bot\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"],\"workflowEngines\":[]}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "creates agent without workflowEngines field defaults to empty",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let svc = mkSvc(store, ws, agents);
        let createR = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"noengine\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"]}");
        expect.bool(isOk(createR)).isTrue();
        // Verify via GET that workflowEngines is []
        let agentId = switch (AgentModel.lookupByName(agents, "noengine")) {
          case (?r) { r.id };
          case (null) { assert false; 0 };
        };
        let nonce2 = WorkflowEnvelopeModel.issue(store, "2_0", 1, [#agents({ access = #read })]).nonce;
        let getR = mkSvc(store, ws, agents).handleRequest(#get, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce2 # "\"}");
        switch (getR.response) {
          case (#ok(body)) {
            expect.bool(Text.contains(body, #text "\"workflowEngines\":[]")).isTrue();
          };
          case (#err(_)) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "unknown workflowEngine string returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/agent", "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"bot\",\"model\":\"gpt-4\",\"allowedChannelIds\":[\"C_GENERAL\"],\"workflowEngines\":[\"unknown-engine\"]}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// GET /agent/{id}
// ============================================

suite(
  "GET /agent/{id}",
  func() {
    test(
      "agents:read token can read an agent in own workspace",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #read })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#get, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "cross-workspace agent access is rejected (workspace boundary)",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        // ws 0 admin agent
        let agentId = switch (AgentModel.register(agents, 0, #_system(#admin), { name = "admin"; model = "m"; workflowEngines = [#canister]; allowedChannelIds = Set.empty(); secrets = { allowed = []; overrides = [] } })) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        // Token is for ws 1
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #read })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#get, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "non-existent agent id returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#agents({ access = #read })], 1);
        let r = svc.handleRequest(#get, "/agent/9999", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /agent/{id} — update
// ============================================

suite(
  "POST /agent/{id} — update",
  func() {
    test(
      "agents:write token can update own workspace agent",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"renamed\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "agents:read token cannot update",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #read })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"renamed\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "cross-workspace agent update is rejected",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        // Agent belongs to ws 0
        let agentId = switch (AgentModel.register(agents, 0, #_system(#admin), { name = "admin"; model = "m"; workflowEngines = [#canister]; allowedChannelIds = Set.empty(); secrets = { allowed = []; overrides = [] } })) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        // Token is for ws 1
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"name\":\"pwned\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "updates workflowEngines to [canister, github]",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"workflowEngines\":[\"canister\",\"github\"]}");
        expect.bool(isOk(r)).isTrue();
        switch (AgentModel.lookupById(agents, agentId)) {
          case (?a) {
            expect.bool(a.config.workflowEngines == [#canister, #github]).isTrue();
          };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "updates workflowEngines to empty []",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"workflowEngines\":[]}");
        expect.bool(isOk(r)).isTrue();
        switch (AgentModel.lookupById(agents, agentId)) {
          case (?a) {
            expect.bool(a.config.workflowEngines == []).isTrue();
          };
          case (null) { expect.bool(false).isTrue() };
        };
      },
    );

    test(
      "unknown workflowEngine string in update returns error",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\",\"workflowEngines\":[\"bad-engine\"]}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// DELETE /agent/{id}
// ============================================

suite(
  "DELETE /agent/{id}",
  func() {
    test(
      "agents:write token can delete own workspace agent",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#delete, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "cross-workspace agent delete is rejected",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        // Agent in ws 0
        let agentId = switch (AgentModel.register(agents, 0, #_system(#admin), { name = "admin"; model = "m"; workflowEngines = [#canister]; allowedChannelIds = Set.empty(); secrets = { allowed = []; overrides = [] } })) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        // Token for ws 1
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#delete, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "agents:read token cannot delete",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#agents({ access = #read })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#delete, "/agent/" # Nat.toText(agentId), "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// GET /slack-queue/stats
// ============================================

suite(
  "GET /slack-queue/stats",
  func() {
    test(
      "slackQueue:read token returns stats",
      func() {
        let (_, _, _, svc, nonce) = issue([#slackQueue({ access = #read })], 0);
        let r = svc.handleRequest(#get, "/slack-queue/stats", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "wrong scope (#workspace) is rejected",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 0);
        let r = svc.handleRequest(#get, "/slack-queue/stats", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// GET /slack-queue/failed
// ============================================

suite(
  "GET /slack-queue/failed",
  func() {
    test(
      "slackQueue:read token returns failed list",
      func() {
        let (_, _, _, svc, nonce) = issue([#slackQueue({ access = #read })], 0);
        let r = svc.handleRequest(#get, "/slack-queue/failed", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "slackQueue:write also covers slackQueue:read",
      func() {
        let (_, _, _, svc, nonce) = issue([#slackQueue({ access = #write })], 0);
        let r = svc.handleRequest(#get, "/slack-queue/failed", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isOk(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /workflow/milestone
// ============================================

suite(
  "POST /workflow/milestone",
  func() {
    test(
      "any valid token emits a #milestone async effect",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workflow/milestone", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"step done\"}");
        expect.bool(isOk(r)).isTrue();
        expect.nat(r.asyncEffects.size()).equal(1);
        expect.bool(
          switch (r.asyncEffects[0]) {
            case (#milestone(_)) { true };
            case (_) { false };
          }
        ).isTrue();
      },
    );

    test(
      "milestone does NOT revoke the token",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#workspace({ access = #read })]).nonce;
        let svc = mkSvc(store, ws, agents);
        ignore svc.handleRequest(#post, "/workflow/milestone", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"step\"}");
        // Token should still be valid after a milestone
        expect.bool(WorkflowEnvelopeModel.validate(store, nonce, #workspace({ access = #read }))).isTrue();
      },
    );

    test(
      "missing humanSummary returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workflow/milestone", "{\"envelopeNonce\":\"" # nonce # "\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "invalid token returns error",
      func() {
        let svc = mkSvc(WorkflowEnvelopeModel.emptyState(), freshWorkspaces(), AgentModel.emptyState());
        let r = svc.handleRequest(#post, "/workflow/milestone", "{\"envelopeNonce\":\"ghost\",\"humanSummary\":\"x\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);

// ============================================
// POST /workflow/complete
// ============================================

suite(
  "POST /workflow/complete",
  func() {
    test(
      "valid token emits a #complete async effect",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\"}");
        expect.bool(isOk(r)).isTrue();
        expect.nat(r.asyncEffects.size()).equal(1);
        expect.bool(
          switch (r.asyncEffects[0]) {
            case (#complete(_)) { true };
            case (_) { false };
          }
        ).isTrue();
      },
    );

    test(
      "complete revokes the token",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#workspace({ access = #read })]).nonce;
        let svc = mkSvc(store, ws, agents);
        ignore svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\"}");
        expect.bool(WorkflowEnvelopeModel.validate(store, nonce, #workspace({ access = #read }))).isFalse();
      },
    );

    test(
      "second call with same (revoked) token is rejected",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#workspace({ access = #read })]).nonce;
        let svc = mkSvc(store, ws, agents);
        ignore svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\"}");
        let r2 = svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\"}");
        expect.bool(isErr(r2)).isTrue();
      },
    );

    test(
      "missing humanSummary returns error",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        let r = svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"status\":\"completed\"}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "missing stats object yields all-null stats in the complete effect",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        // No \"stats\" key at all in the body
        let r = svc.handleRequest(#post, "/workflow/complete", "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\"}");
        expect.bool(isOk(r)).isTrue();
        let stats = switch (r.asyncEffects[0]) {
          case (#complete(e)) { e.stats };
          case (_) { assert false; loop {} };
        };
        expect.option(stats.durationNs, Int.toText, Int.equal).isNull();
        expect.option(stats.llmCalls, Nat.toText, Nat.equal).isNull();
        expect.option(stats.model, func(v : Text) : Text { v }, Text.equal).isNull();
      },
    );

    test(
      "misconfigured stats field (wrong type) yields null for that field",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #read })], 1);
        // rounds is a string instead of a number; durationNs and model are valid
        let body = "{\"envelopeNonce\":\"" # nonce # "\",\"humanSummary\":\"done\",\"status\":\"completed\",\"stats\":{\"durationNs\":500,\"rounds\":\"not-a-number\",\"model\":\"gpt-4\"}}";
        let r = svc.handleRequest(#post, "/workflow/complete", body);
        expect.bool(isOk(r)).isTrue();
        let stats = switch (r.asyncEffects[0]) {
          case (#complete(e)) { e.stats };
          case (_) { assert false; loop {} };
        };
        expect.option(stats.durationNs, Int.toText, Int.equal).isSome();
        expect.option(stats.rounds, Nat.toText, Nat.equal).isNull();
        expect.option(stats.model, func(v : Text) : Text { v }, Text.equal).isSome();
      },
    );
  },
);

// ============================================
// POST /session/policy
// ============================================

suite(
  "POST /session/policy",
  func() {
    test(
      "session:write token can update policy for own workspace agent",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        let agentId = switch (AgentModel.register(agents, 1, #custom, customCfg)) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let sessions = SessionModel.emptyStores();
        ignore SessionModel.getOrCreateSession(sessions, agentId);
        let deps : WorkflowApiService.ServiceDeps = {
          envelopeState = store;
          workspaces = ws;
          agentRegistry = agents;
          approvalState = ApprovalModel.emptyState();
          eventStore = EventStoreModel.empty();
          sessionStores = sessions;
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#session({ access = #write })]).nonce;
        let svc = WorkflowApiService.Service(deps);
        let r = svc.handleRequest(#post, "/session/policy", "{\"envelopeNonce\":\"" # nonce # "\",\"agentId\":" # Nat.toText(agentId) # ",\"summaryTokenBudget\":4096,\"maxTruncatedTokens\":512}");
        expect.bool(isOk(r)).isTrue();
      },
    );

    test(
      "wrong scope (#workspace) is rejected for session/policy",
      func() {
        let (_, _, _, svc, nonce) = issue([#workspace({ access = #write })], 1);
        let r = svc.handleRequest(#post, "/session/policy", "{\"envelopeNonce\":\"" # nonce # "\",\"agentId\":0,\"summaryTokenBudget\":4096,\"maxTruncatedTokens\":512}");
        expect.bool(isErr(r)).isTrue();
      },
    );

    test(
      "cross-workspace agent is rejected for session/policy",
      func() {
        let store = WorkflowEnvelopeModel.emptyState();
        let ws = freshWorkspaces();
        let agents = AgentModel.emptyState();
        // Agent in ws 0; token for ws 1
        let agentId = switch (AgentModel.register(agents, 0, #_system(#admin), { name = "admin"; model = "m"; workflowEngines = [#canister]; allowedChannelIds = Set.empty(); secrets = { allowed = []; overrides = [] } })) {
          case (#ok(id)) { id };
          case (#err(_)) { assert false; 0 };
        };
        let nonce = WorkflowEnvelopeModel.issue(store, "1_0", 1, [#session({ access = #write })]).nonce;
        let r = mkSvc(store, ws, agents).handleRequest(#post, "/session/policy", "{\"envelopeNonce\":\"" # nonce # "\",\"agentId\":" # Nat.toText(agentId) # ",\"summaryTokenBudget\":4096,\"maxTruncatedTokens\":512}");
        expect.bool(isErr(r)).isTrue();
      },
    );
  },
);
