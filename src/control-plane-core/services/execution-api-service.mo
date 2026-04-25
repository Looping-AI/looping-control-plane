import Json "mo:json";
import { str; obj; arr; int } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Text "mo:core/Text";
import List "mo:core/List";
import Set "mo:core/Set";
import WorkspaceModel "../models/workspace-model";
import AgentModel "../models/agent-model";
import EventStoreModel "../models/event-store-model";
import SessionModel "../models/session-model";
import ExecutionTypes "../types/execution";
import ExecutionEnvelopeModel "../models/execution-envelope-model";

module {

  // ── Dependencies (threaded from main.mo) ───────────────────────────

  public type ServiceDeps = {
    envelopeState : ExecutionEnvelopeModel.EnvelopeState;
    workspaces : WorkspaceModel.WorkspacesState;
    agentRegistry : AgentModel.AgentRegistryState;
    eventStore : EventStoreModel.EventStoreState;
    sessionStores : SessionModel.SessionStores;
  };

  public class Service(deps : ServiceDeps) {

    // ── Main handler (synchronous — NOT async) ─────────────────────────

    public func handleRequest(
      method : ExecutionTypes.HttpMethod,
      path : Text,
      body : Text,
    ) : ExecutionTypes.HandleResult {
      let asyncEffects = List.empty<ExecutionTypes.AsyncEffect>();

      // 1. Parse JSON body
      let parsed = switch (Json.parse(body)) {
        case (#err(_)) {
          return result(errorResponse("Invalid JSON in request body"), asyncEffects);
        };
        case (#ok(json)) { json };
      };

      // 2. Extract envelopeNonce from body
      let envelopeNonce = switch (Json.get(parsed, "envelopeNonce")) {
        case (?#string(n)) { n };
        case (_) {
          return result(errorResponse("Missing or invalid 'envelopeNonce'"), asyncEffects);
        };
      };

      // 3. Parse path segments and dispatch
      let segments = parsePath(path);
      let response = switch (segments.size()) {

        // ── Single-segment routes (collection-level) ───────────────
        case 1 {
          switch (method, segments[0]) {
            // #workspace scoped routes
            case (#get, "workspace") {
              handleWorkspaceGet(envelopeNonce);
            };
            case (#post, "workspace") {
              handleWorkspaceCreate(envelopeNonce, parsed);
            };

            // #agents scoped routes
            case (#get, "agent") { handleAgentList(envelopeNonce) };
            case (#post, "agent") { handleAgentCreate(envelopeNonce, parsed) };

            case _ { errorResponse("Not found: " # path) };
          };
        };

        // ── Two-segment routes (resource-level or event sub-action) ─
        case 2 {
          let (seg0, seg1) = (segments[0], segments[1]);
          switch (method, seg0) {
            // #workspace scoped routes
            case (#post, "workspace") {
              switch (seg1) {
                case "update" {
                  handleWorkspaceUpdate(envelopeNonce, parsed);
                };
                case "admin-channel" {
                  handleSetAdminChannel(envelopeNonce, parsed);
                };
                case _ { errorResponse("Not found: POST /workspace/" # seg1) };
              };
            };
            case (#delete, "workspace") {
              handleWorkspaceDelete(envelopeNonce, seg1);
            };

            // #agents scoped routes
            case (#get, "agent") { handleAgentGet(envelopeNonce, seg1) }; // #agent scope route
            case (#post, "agent") {
              handleAgentUpdate(envelopeNonce, seg1, parsed);
            };
            case (#delete, "agent") {
              handleAgentDelete(envelopeNonce, seg1);
            };

            // Slack Queue routes
            case (#get, "slack-queue") {
              switch (seg1) {
                case "stats" { handleSlackQueueStats(envelopeNonce) };
                case "failed" { handleSlackQueueFailedList(envelopeNonce) };
                case _ { errorResponse("Not found: GET /slack-queue/" # seg1) };
              };
            };

            // Execution webhook
            case (#post, "execution") {
              switch (seg1) {
                case "milestone" {
                  handleEventMilestone(envelopeNonce, asyncEffects, parsed);
                };
                case "complete" {
                  handleEventComplete(envelopeNonce, asyncEffects, parsed);
                };
                case _ { errorResponse("Not found: POST /execution/" # seg1) };
              };
            };

            // Agent Session Policy routes
            case (#post, "session") {
              switch (seg1) {
                case "policy" {
                  handleSessionPolicy(envelopeNonce, parsed);
                };
                case _ {
                  errorResponse("Not found: POST /session/" # seg1);
                };
              };
            };
            case _ { errorResponse("Not found: " # path) };
          };
        };

        case _ { errorResponse("Not found: " # path) };
      };

      result(response, asyncEffects);
    };

    // ── Token helpers ────────────────────────────────────────────────────

    /// Extract the workspace ID bound to a token. Returns null for invalid/expired tokens.
    private func getTokenWorkspaceId(envelopeNonce : Text) : ?Nat {
      switch (ExecutionEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) { null };
        case (?record) { ?record.workspaceId };
      };
    };

    /// Validates a scope grant and extracts the workspace ID from the token in one step.
    /// Returns #err if scope is missing or the token is invalid/expired.
    private func requireScope(
      envelopeNonce : Text,
      grant : ExecutionTypes.ScopeGrant,
    ) : { #ok : Nat; #err : Text } {
      switch (checkGrant(envelopeNonce, grant)) {
        case (#err(e)) { #err(e) };
        case (#ok) {
          switch (getTokenWorkspaceId(envelopeNonce)) {
            case (null) { #err("Invalid or expired token") };
            case (?ws) { #ok(ws) };
          };
        };
      };
    };

    /// Looks up an agent and verifies it belongs to the token's workspace.
    /// Defense-in-depth: the token workspaceId equals agent.ownedBy at dispatch time,
    /// so a mismatch indicates a programming error or a tampered token.
    private func requireOwnedAgent(
      tokenWs : Nat,
      agentId : Nat,
    ) : { #ok : AgentModel.AgentRecord; #err : Text } {
      switch (AgentModel.lookupById(deps.agentRegistry, agentId)) {
        case (null) { #err("Agent not found") };
        case (?a) {
          if (a.ownedBy != tokenWs) {
            #err("Workspace boundary violation: agent not owned by token workspace");
          } else {
            #ok(a);
          };
        };
      };
    };

    // ── Workspace handlers ─────────────────────────────────────────────

    /// Returns the token's own workspace.
    private func handleWorkspaceGet(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #read }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      switch (WorkspaceModel.getWorkspace(deps.workspaces, tokenWs)) {
        case (null) { errorResponse("Workspace not found") };
        case (?w) { okResponse(?workspaceRecordToJson(w)) };
      };
    };

    private func handleWorkspaceCreate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      // Only org admin (ws 0) can create new workspaces
      if (tokenWs != 0) {
        return errorResponse("Only org admin can create workspaces");
      };
      let name = switch (requireString(body, "name")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      switch (WorkspaceModel.createWorkspace(deps.workspaces, name)) {
        case (#ok(id)) { okResponse(?int(id)) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    /// Updates the token's own workspace.
    private func handleWorkspaceUpdate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      let newName = switch (requireString(body, "name")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      switch (WorkspaceModel.renameWorkspace(deps.workspaces, tokenWs, newName)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    private func handleWorkspaceDelete(envelopeNonce : Text, idStr : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let workspaceId = switch (Nat.fromText(idStr)) {
        case (null) { return errorResponse("Invalid workspace id: " # idStr) };
        case (?id) { id };
      };
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      // Only org admin (ws 0) can delete workspaces
      if (tokenWs != 0) {
        return errorResponse("Only org admin can delete workspaces");
      };
      // Require a matching #deleteWorkspace permit (pre-validated at Core dispatch)
      if (not ExecutionEnvelopeModel.hasPermit(deps.envelopeState, envelopeNonce, #deleteWorkspace({ workspaceId }))) {
        return errorResponse("Missing #deleteWorkspace permit for workspace " # idStr);
      };
      switch (WorkspaceModel.deleteWorkspace(deps.workspaces, workspaceId)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    // ── Agent handlers ─────────────────────────────────────────────────

    private func handleAgentList(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #read }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      let agents = AgentModel.listAgents(deps.agentRegistry);
      let items = List.empty<Json.Json>();
      for (a in agents.vals()) {
        // Workspace boundary: only show agents owned by token's workspace
        if (a.ownedBy == tokenWs) {
          List.add(items, agentRecordToJson(a));
        };
      };
      okResponse(?arr(List.toArray(items)));
    };

    private func handleAgentGet(envelopeNonce : Text, idStr : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) { return errorResponse("Invalid agent id: " # idStr) };
        case (?id) { id };
      };
      // Admins (agents:read) can get any agent in their workspace.
      // Non-admin agents can only read their own record (#agent scope with matching id).
      if (
        not validateScope(envelopeNonce, #agents({ access = #read })) and
        not validateScope(envelopeNonce, #agent({ id = agentId; access = #read }))
      ) {
        return errorResponse("Token does not grant access to agent:" # idStr);
      };
      let tokenWs = switch (getTokenWorkspaceId(envelopeNonce)) {
        case (null) { return errorResponse("Invalid or expired token") };
        case (?ws) { ws };
      };
      let agent = switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(a)) { a };
      };
      okResponse(?agentRecordToJson(agent));
    };

    private func handleAgentCreate(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      let name = switch (requireString(body, "name")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      let model = switch (requireString(body, "model")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      // workspaceId is implicit from token — NOT accepted in body
      let channelSet = switch (Json.get(body, "allowedChannelIds")) {
        case (?#array(items)) {
          let set = Set.empty<Text>();
          for (item in items.vals()) {
            switch (item) {
              case (#string(s)) { Set.add(set, Text.compare, s) };
              case _ {
                return errorResponse("'allowedChannelIds' must be an array of strings");
              };
            };
          };
          set;
        };
        case (_) {
          return errorResponse("Missing or invalid 'allowedChannelIds' field");
        };
      };
      let engines = switch (parseOptionalExecutionEngines(body)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(null)) { [] };
        case (#ok(?e)) { e };
      };
      let config : AgentModel.AgentConfig = {
        name;
        model;
        executionEngines = engines;
        allowedChannelIds = channelSet;
        secrets = { allowed = []; overrides = [] };
      };
      switch (AgentModel.register(deps.agentRegistry, tokenWs, #custom, config)) {
        case (#ok(id)) { okResponse(?int(id)) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    private func handleAgentUpdate(envelopeNonce : Text, idStr : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) { return errorResponse("Invalid agent id: " # idStr) };
        case (?id) { id };
      };
      // 1. Check scope authorization
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      // 2. Check agent ownership (workspace boundary)
      switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(_)) {};
      };
      let newName = switch (Json.get(body, "name")) {
        case (?#string(n)) { ?n };
        case (_) { null };
      };
      let newModel = switch (Json.get(body, "model")) {
        case (?#string(m)) { ?m };
        case (_) { null };
      };
      let newEngines = switch (parseOptionalExecutionEngines(body)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      switch (AgentModel.updateById(deps.agentRegistry, agentId, { name = newName; model = newModel; executionEngines = newEngines; secretsAllowed = null; secretOverrides = null; allowedChannelIds = null })) {
        case (#ok(_)) { okResponse(null) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    // ── Agent delete handler ────────────────────────────────────────────

    private func handleAgentDelete(envelopeNonce : Text, idStr : Text) : {
      #ok : Text;
      #err : Text;
    } {
      let agentId = switch (Nat.fromText(idStr)) {
        case (null) { return errorResponse("Invalid agent id: " # idStr) };
        case (?id) { id };
      };
      // 1. Check scope authorization
      let tokenWs = switch (requireScope(envelopeNonce, #agents({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      // 2. Check agent ownership (workspace boundary)
      switch (requireOwnedAgent(tokenWs, agentId)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(_)) {};
      };
      switch (AgentModel.unregisterById(deps.agentRegistry, agentId)) {
        case (#ok(_)) { okResponse(null) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    // ── Admin channel handler ──────────────────────────────────────────

    /// Sets admin channel on the token's own workspace.
    private func handleSetAdminChannel(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #workspace({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      let channelId = switch (requireString(body, "channelId")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(v)) { v };
      };
      // Require a matching #setAdminChannel permit (pre-validated at Core dispatch)
      if (not ExecutionEnvelopeModel.hasPermit(deps.envelopeState, envelopeNonce, #setAdminChannel({ channelId }))) {
        return errorResponse("Missing #setAdminChannel permit for channel " # channelId);
      };
      switch (WorkspaceModel.setAdminChannel(deps.workspaces, tokenWs, channelId)) {
        case (#ok(())) { okResponse(null) };
        case (#err(e)) { errorResponse(e) };
      };
    };

    // ── Event handlers ─────────────────────────────────────────────────

    private func handleSlackQueueStats(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      switch (checkGrant(envelopeNonce, #slackQueue({ access = #read }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok) {};
      };
      let stats = EventStoreModel.sizes(deps.eventStore);
      okResponse(?obj([("unprocessed", int(stats.unprocessed)), ("processed", int(stats.processed)), ("failed", int(stats.failed))]));
    };

    private func handleSlackQueueFailedList(envelopeNonce : Text) : {
      #ok : Text;
      #err : Text;
    } {
      switch (checkGrant(envelopeNonce, #slackQueue({ access = #read }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok) {};
      };
      let failed = EventStoreModel.listFailed(deps.eventStore);
      let items = List.empty<Json.Json>();
      for (e in failed.vals()) {
        List.add(
          items,
          obj([
            ("eventId", str(e.eventId)),
            ("error", str(e.failedError)),
          ]),
        );
      };
      okResponse(?arr(List.toArray(items)));
    };

    // ── Session handler ────────────────────────────────────────────────

    private func handleSessionPolicy(envelopeNonce : Text, body : Json.Json) : {
      #ok : Text;
      #err : Text;
    } {
      let tokenWs = switch (requireScope(envelopeNonce, #session({ access = #write }))) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(ws)) { ws };
      };
      let agentIdNum = switch (parsePositiveNat(body, "agentId")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(n)) { n };
      };
      // Workspace boundary: can only update session policy for own agents
      switch (requireOwnedAgent(tokenWs, agentIdNum)) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(_)) {};
      };
      let summaryBudget = switch (parsePositiveNat(body, "summaryTokenBudget")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(n)) { n };
      };
      let maxTruncated = switch (parsePositiveNat(body, "maxTruncatedTokens")) {
        case (#err(e)) { return errorResponse(e) };
        case (#ok(n)) { n };
      };
      let policy : SessionModel.SessionPolicy = {
        summaryTokenBudget = summaryBudget;
        maxTruncatedTokens = maxTruncated;
      };
      if (SessionModel.updateSessionPolicy(deps.sessionStores, agentIdNum, policy)) {
        okResponse(null);
      } else {
        errorResponse("Failed to update session policy");
      };
    };

    // ── Event milestone/complete handlers ──────────────────────────────

    private func handleEventMilestone(
      envelopeNonce : Text,
      asyncEffects : List.List<ExecutionTypes.AsyncEffect>,
      body : Json.Json,
    ) : {
      #ok : Text;
      #err : Text;
    } {
      let record = switch (ExecutionEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) { return errorResponse("Invalid or expired token") };
        case (?r) { r };
      };
      let humanSummary = switch (Json.get(body, "humanSummary")) {
        case (?#string(s)) { s };
        case (_) { return errorResponse("Missing 'humanSummary' field") };
      };
      let stepsDetail = parseStepsDetail(body);
      List.add(
        asyncEffects,
        #milestone({
          envelopeId = record.envelopeId;
          turnId = record.turnId;
          humanSummary;
          stepsDetail;
        }),
      );
      okResponse(null);
    };

    private func handleEventComplete(
      envelopeNonce : Text,
      asyncEffects : List.List<ExecutionTypes.AsyncEffect>,
      body : Json.Json,
    ) : {
      #ok : Text;
      #err : Text;
    } {
      let record = switch (ExecutionEnvelopeModel.getRecord(deps.envelopeState, envelopeNonce)) {
        case (null) { return errorResponse("Invalid or expired token") };
        case (?r) { r };
      };
      let humanSummary = switch (Json.get(body, "humanSummary")) {
        case (?#string(s)) { s };
        case (_) { return errorResponse("Missing 'humanSummary' field") };
      };
      let stepsDetail = parseStepsDetail(body);
      let status = parseExecutionStatus(body);
      let stats = parseExecutionStats(body);

      // Revoke token immediately (defense-in-depth)
      ExecutionEnvelopeModel.revoke(deps.envelopeState, envelopeNonce);

      List.add(
        asyncEffects,
        #complete({
          envelopeId = record.envelopeId;
          turnId = record.turnId;
          humanSummary;
          stepsDetail;
          status;
          stats;
        }),
      );
      okResponse(null);
    };

    // ── Response builders ───────────────────────────────────────────────

    private func result(
      response : { #ok : Text; #err : Text },
      asyncEffects : List.List<ExecutionTypes.AsyncEffect>,
    ) : ExecutionTypes.HandleResult {
      { response; asyncEffects = List.toArray(asyncEffects) };
    };

    private func okResponse(data : ?Json.Json) : { #ok : Text; #err : Text } {
      switch (data) {
        case (?d) { #ok(Json.stringify(d, null)) };
        case (null) { #ok("{}") };
      };
    };

    private func errorResponse(message : Text) : { #ok : Text; #err : Text } {
      #err(message);
    };

    // ── Serialization helpers ──────────────────────────────────────────

    private func workspaceRecordToJson(w : WorkspaceModel.WorkspaceRecord) : Json.Json {
      let fields = List.empty<(Text, Json.Json)>();
      List.add(fields, ("id", int(w.id)));
      List.add(fields, ("name", str(w.name)));
      switch (w.adminChannelId) {
        case (?ch) { List.add(fields, ("adminChannelId", str(ch))) };
        case (null) {};
      };
      obj(List.toArray(fields));
    };

    private func agentRecordToJson(a : AgentModel.AgentRecord) : Json.Json {
      let categoryText = switch (a.category) {
        case (#_system(#admin)) { "system:admin" };
        case (#_system(#onboarding)) { "system:onboarding" };
        case (#custom) { "custom" };
      };
      let engineItems = List.empty<Json.Json>();
      for (e in a.config.executionEngines.vals()) {
        List.add(engineItems, str(executionEngineToText(e)));
      };
      obj([
        ("id", int(a.id)),
        ("ownedBy", int(a.ownedBy)),
        ("category", str(categoryText)),
        ("name", str(a.config.name)),
        ("model", str(a.config.model)),
        ("executionEngines", arr(List.toArray(engineItems))),
      ]);
    };

    // ── ExecutionEngine helpers ─────────────────────────────────────────

    private func executionEngineToText(e : AgentModel.ExecutionEngine) : Text {
      switch (e) {
        case (#canister) { "canister" };
        case (#github) { "github" };
      };
    };

    /// Parses an optional "executionEngines" array from the request body.
    /// - Key absent → #ok(null)  (caller chooses the default)
    /// - Key present, valid strings → #ok(?engines)
    /// - Key present, invalid → #err
    private func parseOptionalExecutionEngines(body : Json.Json) : {
      #ok : ?[AgentModel.ExecutionEngine];
      #err : Text;
    } {
      switch (Json.get(body, "executionEngines")) {
        case (null) { #ok(null) };
        case (?#array(items)) {
          let engines = List.empty<AgentModel.ExecutionEngine>();
          for (item in items.vals()) {
            switch (item) {
              case (#string("canister")) { List.add(engines, #canister) };
              case (#string("github")) { List.add(engines, #github) };
              case (#string(s)) {
                return #err("Unknown executionEngine value: '" # s # "'");
              };
              case (_) {
                return #err("'executionEngines' must be an array of strings");
              };
            };
          };
          #ok(?List.toArray(engines));
        };
        case (_) {
          #err("'executionEngines' must be an array");
        };
      };
    };

    // ── Path parsing ───────────────────────────────────────────────────

    private func parsePath(path : Text) : [Text] {
      let parts = Text.split(path, #char '/');
      let segments = List.empty<Text>();
      for (p in parts) {
        if (Text.size(p) > 0) {
          List.add(segments, p);
        };
      };
      List.toArray(segments);
    };

    // ── Body field parsing helpers ─────────────────────────────────────

    /// Extracts a required string field from a JSON body object.
    private func requireString(body : Json.Json, key : Text) : {
      #ok : Text;
      #err : Text;
    } {
      switch (Json.get(body, key)) {
        case (?#string(v)) { #ok(v) };
        case (_) { #err("Missing '" # key # "' field") };
      };
    };

    /// Extracts a required non-negative number field and returns it as Nat.
    private func parsePositiveNat(body : Json.Json, key : Text) : {
      #ok : Nat;
      #err : Text;
    } {
      switch (Json.get(body, key)) {
        case (?#number(#int(n))) {
          if (n < 0) { #err("Invalid '" # key # "'") } else {
            #ok(Nat.fromInt(n));
          };
        };
        case (_) { #err("Missing or invalid '" # key # "' field") };
      };
    };

    private func parseStepsDetail(body : Json.Json) : [ExecutionTypes.SummarizedStep] {
      switch (Json.get(body, "stepsDetail")) {
        case (?#array(items)) {
          let steps = List.empty<ExecutionTypes.SummarizedStep>();
          for (item in items.vals()) {
            let tool = switch (Json.get(item, "tool")) {
              case (?#string(t)) { t };
              case (_) { "unknown" };
            };
            let summary = switch (Json.get(item, "summary")) {
              case (?#string(s)) { s };
              case (_) { "" };
            };
            let success = switch (Json.get(item, "success")) {
              case (?#bool(b)) { b };
              case (_) { false };
            };
            List.add(steps, { tool; summary; success });
          };
          List.toArray(steps);
        };
        case (_) { [] };
      };
    };

    private func parseExecutionStatus(body : Json.Json) : ExecutionTypes.ExecutionStatus {
      switch (Json.get(body, "status")) {
        case (?#string("completed")) { #completed };
        case (?#string("roundLimitReached")) { #roundLimitReached };
        case (?#string("failed")) {
          let reason = switch (Json.get(body, "statusReason")) {
            case (?#string(r)) { r };
            case (_) { "Unknown failure" };
          };
          #failed(reason);
        };
        case (_) { #failed("Unknown status") };
      };
    };

    private func parseExecutionStats(body : Json.Json) : ExecutionTypes.ExecutionStats {
      let statsObj = switch (Json.get(body, "stats")) {
        case (?obj) { obj };
        case (null) {
          return {
            durationNs = null;
            llmCalls = null;
            toolCalls = null;
            inputTokens = null;
            outputTokens = null;
            model = null;
            rounds = null;
            estimatedDollarCost = null;
          };
        };
      };
      let getOptInt = func(key : Text) : ?Int {
        switch (Json.get(statsObj, key)) {
          case (?#number(#int(n))) { ?n };
          case (?#number(#float(f))) { ?Float.toInt(f) };
          case (_) { null };
        };
      };
      let getOptNat = func(key : Text) : ?Nat {
        switch (getOptInt(key)) {
          case (?n) { if (n < 0) { null } else { ?Nat.fromInt(n) } };
          case (null) { null };
        };
      };
      {
        durationNs = getOptInt("durationNs");
        llmCalls = getOptNat("llmCalls");
        toolCalls = getOptNat("toolCalls");
        inputTokens = getOptNat("inputTokens");
        outputTokens = getOptNat("outputTokens");
        model = switch (Json.get(statsObj, "model")) {
          case (?#string(m)) { ?m };
          case (_) { null };
        };
        rounds = getOptNat("rounds");
        estimatedDollarCost = switch (Json.get(statsObj, "estimatedDollarCost")) {
          case (?#number(#float(f))) { ?f };
          case (?#number(#int(i))) { ?Float.fromInt(i) };
          case (_) { null };
        };
      };
    };

    // ── Scope validation ───────────────────────────────────────────────
    private func accessText(access : ExecutionTypes.ScopeAccess) : Text {
      switch (access) {
        case (#read) { "read" };
        case (#write) { "write" };
      };
    };

    private func grantText(grant : ExecutionTypes.ScopeGrant) : Text {
      switch (grant) {
        case (#workspace(w)) { "workspace:" # accessText(w.access) };
        case (#agents(a)) { "agents:" # accessText(a.access) };
        case (#agent(a)) {
          "agent:" # Nat.toText(a.id) # ":" # accessText(a.access);
        };
        case (#slackQueue(s)) { "slack-queue:" # accessText(s.access) };
        case (#session(s)) { "session:" # accessText(s.access) };
      };
    };

    /// Checks a scope grant, returning #ok or a derived error message on failure.
    private func checkGrant(
      envelopeNonce : Text,
      grant : ExecutionTypes.ScopeGrant,
    ) : { #ok; #err : Text } {
      if (validateScope(envelopeNonce, grant)) { #ok } else {
        #err("Token does not grant " # grantText(grant));
      };
    };
    private func validateScope(
      envelopeNonce : Text,
      requiredGrant : ExecutionTypes.ScopeGrant,
    ) : Bool {
      ExecutionEnvelopeModel.validate(deps.envelopeState, envelopeNonce, requiredGrant);
    };

  }; // end class Service

};
