import Json "mo:json";
import { str; obj; arr; int } "mo:json";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Text "mo:core/Text";
import List "mo:core/List";
import Set "mo:core/Set";
import WorkspaceModel "../models/workspace-model";
import AgentModel "../models/agent-model";
import ExecutionTypes "../types/execution";
import ExecutionTokenService "execution-token-service";

module {

  // ── Dependencies (threaded from main.mo) ───────────────────────────

  public type ServiceDeps = {
    tokenStore : ExecutionTokenService.TokenStore;
    workspaces : WorkspaceModel.WorkspacesState;
    agentRegistry : AgentModel.AgentRegistryState;
  };

  // ── Main handler (synchronous — NOT async) ─────────────────────────

  public func handleRequest(
    method : ExecutionTypes.HttpMethod,
    path : Text,
    body : Text,
    deps : ServiceDeps,
  ) : ExecutionTypes.HandleResult {
    let asyncEffects = List.empty<ExecutionTypes.AsyncEffect>();

    // 1. Parse JSON body
    let parsed = switch (Json.parse(body)) {
      case (#err(_)) {
        return result(errorResponse("Invalid JSON in request body"), asyncEffects);
      };
      case (#ok(json)) { json };
    };

    // 2. Extract tokenNonce from body
    let tokenNonce = switch (Json.get(parsed, "tokenNonce")) {
      case (?#string(n)) { n };
      case (_) {
        return result(errorResponse("Missing or invalid 'tokenNonce'"), asyncEffects);
      };
    };

    // 3. Parse path segments and dispatch
    let segments = parsePath(path);
    let response = switch (segments.size()) {

      // ── Single-segment routes (collection-level) ───────────────
      case 1 {
        switch (method, segments[0]) {
          case (#get, "workspace") { handleWorkspaceList(deps, tokenNonce) };
          case (#post, "workspace") {
            handleWorkspaceCreate(deps, tokenNonce, parsed);
          };
          case (#get, "agent") { handleAgentList(deps, tokenNonce) };
          case (#post, "agent") { handleAgentCreate(deps, tokenNonce, parsed) };
          case _ { errorResponse("Not found: " # path) };
        };
      };

      // ── Two-segment routes (resource-level or event sub-action) ─
      case 2 {
        let (seg0, seg1) = (segments[0], segments[1]);
        switch (method, seg0) {
          case (#get, "workspace") {
            handleWorkspaceGet(deps, tokenNonce, seg1);
          };
          case (#post, "workspace") {
            handleWorkspaceUpdate(deps, tokenNonce, seg1, parsed);
          };
          case (#delete, "workspace") {
            handleWorkspaceDelete(deps, tokenNonce, seg1);
          };
          case (#get, "agent") { handleAgentGet(deps, tokenNonce, seg1) };
          case (#post, "agent") {
            handleAgentUpdate(deps, tokenNonce, seg1, parsed);
          };
          case (#post, "event") {
            switch (seg1) {
              case "milestone" {
                handleEventMilestone(deps, tokenNonce, asyncEffects, parsed);
              };
              case "complete" {
                handleEventComplete(deps, tokenNonce, asyncEffects, parsed);
              };
              case _ { errorResponse("Not found: POST /event/" # seg1) };
            };
          };
          case _ { errorResponse("Not found: " # path) };
        };
      };

      case _ { errorResponse("Not found: " # path) };
    };

    result(response, asyncEffects);
  };

  // ── Workspace handlers ─────────────────────────────────────────────

  private func handleWorkspaceList(deps : ServiceDeps, tokenNonce : Text) : {
    #ok : Text;
    #err : Text;
  } {
    let workspaces = WorkspaceModel.listWorkspaces(deps.workspaces);
    let items = List.empty<Json.Json>();
    for (w in workspaces.vals()) {
      if (validateScope(deps, tokenNonce, #workspace({ id = ?w.id; access = #read }))) {
        List.add(items, workspaceRecordToJson(w));
      };
    };
    okResponse(?arr(List.toArray(items)));
  };

  private func handleWorkspaceGet(deps : ServiceDeps, tokenNonce : Text, idStr : Text) : {
    #ok : Text;
    #err : Text;
  } {
    let workspaceId = switch (Nat.fromText(idStr)) {
      case (null) { return errorResponse("Invalid workspace id: " # idStr) };
      case (?id) { id };
    };
    if (not validateScope(deps, tokenNonce, #workspace({ id = ?workspaceId; access = #read }))) {
      return errorResponse("Token does not grant workspace:" # idStr # ":read");
    };
    switch (WorkspaceModel.getWorkspace(deps.workspaces, workspaceId)) {
      case (null) { errorResponse("Workspace not found") };
      case (?w) { okResponse(?workspaceRecordToJson(w)) };
    };
  };

  private func handleWorkspaceCreate(deps : ServiceDeps, tokenNonce : Text, body : Json.Json) : {
    #ok : Text;
    #err : Text;
  } {
    if (not validateScope(deps, tokenNonce, #workspace({ id = null; access = #write }))) {
      return errorResponse("Token does not grant workspace:create");
    };
    let name = switch (Json.get(body, "name")) {
      case (?#string(n)) { n };
      case (_) { return errorResponse("Missing 'name' field") };
    };
    switch (WorkspaceModel.createWorkspace(deps.workspaces, name)) {
      case (#ok(id)) { okResponse(?int(id)) };
      case (#err(e)) { errorResponse(e) };
    };
  };

  private func handleWorkspaceUpdate(deps : ServiceDeps, tokenNonce : Text, idStr : Text, body : Json.Json) : {
    #ok : Text;
    #err : Text;
  } {
    let workspaceId = switch (Nat.fromText(idStr)) {
      case (null) { return errorResponse("Invalid workspace id: " # idStr) };
      case (?id) { id };
    };
    if (not validateScope(deps, tokenNonce, #workspace({ id = ?workspaceId; access = #write }))) {
      return errorResponse("Token does not grant workspace:" # idStr # ":write");
    };
    let newName = switch (Json.get(body, "name")) {
      case (?#string(n)) { n };
      case (_) { return errorResponse("Missing 'name' field") };
    };
    switch (WorkspaceModel.renameWorkspace(deps.workspaces, workspaceId, newName)) {
      case (#ok(())) { okResponse(null) };
      case (#err(e)) { errorResponse(e) };
    };
  };

  private func handleWorkspaceDelete(deps : ServiceDeps, tokenNonce : Text, idStr : Text) : {
    #ok : Text;
    #err : Text;
  } {
    let workspaceId = switch (Nat.fromText(idStr)) {
      case (null) { return errorResponse("Invalid workspace id: " # idStr) };
      case (?id) { id };
    };
    if (not validateScope(deps, tokenNonce, #workspace({ id = ?workspaceId; access = #write }))) {
      return errorResponse("Token does not grant workspace:" # idStr # ":write");
    };
    switch (WorkspaceModel.deleteWorkspace(deps.workspaces, workspaceId)) {
      case (#ok(())) { okResponse(null) };
      case (#err(e)) { errorResponse(e) };
    };
  };

  // ── Agent handlers ─────────────────────────────────────────────────

  private func handleAgentList(deps : ServiceDeps, tokenNonce : Text) : {
    #ok : Text;
    #err : Text;
  } {
    let agents = AgentModel.listAgents(deps.agentRegistry);
    let items = List.empty<Json.Json>();
    for (a in agents.vals()) {
      if (validateScope(deps, tokenNonce, #agent({ id = ?a.id; access = #read }))) {
        List.add(items, agentRecordToJson(a));
      };
    };
    okResponse(?arr(List.toArray(items)));
  };

  private func handleAgentGet(deps : ServiceDeps, tokenNonce : Text, idStr : Text) : {
    #ok : Text;
    #err : Text;
  } {
    let agentId = switch (Nat.fromText(idStr)) {
      case (null) { return errorResponse("Invalid agent id: " # idStr) };
      case (?id) { id };
    };
    if (not validateScope(deps, tokenNonce, #agent({ id = ?agentId; access = #read }))) {
      return errorResponse("Token does not grant agent:" # idStr # ":read");
    };
    switch (AgentModel.lookupById(deps.agentRegistry, agentId)) {
      case (null) { errorResponse("Agent not found") };
      case (?a) { okResponse(?agentRecordToJson(a)) };
    };
  };

  private func handleAgentCreate(deps : ServiceDeps, tokenNonce : Text, body : Json.Json) : {
    #ok : Text;
    #err : Text;
  } {
    if (not validateScope(deps, tokenNonce, #agent({ id = null; access = #write }))) {
      return errorResponse("Token does not grant agent:create");
    };
    let name = switch (Json.get(body, "name")) {
      case (?#string(n)) { n };
      case (_) { return errorResponse("Missing 'name' field") };
    };
    let model = switch (Json.get(body, "model")) {
      case (?#string(m)) { m };
      case (_) { return errorResponse("Missing 'model' field") };
    };
    let workspaceId = switch (Json.get(body, "workspaceId")) {
      case (?#number(#int(n))) {
        if (n < 0) { return errorResponse("Invalid 'workspaceId'") } else {
          Nat.fromInt(n);
        };
      };
      case (?#number(#float(f))) {
        let n = Float.toInt(f);
        if (n < 0) { return errorResponse("Invalid 'workspaceId'") } else {
          Nat.fromInt(n);
        };
      };
      case (_) {
        return errorResponse("Missing or invalid 'workspaceId' field");
      };
    };
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
    let config : AgentModel.AgentConfig = {
      name;
      model;
      executionEngines = [#canister];
      allowedChannelIds = channelSet;
      secrets = { allowed = []; overrides = [] };
    };
    switch (AgentModel.register(deps.agentRegistry, workspaceId, #custom, config)) {
      case (#ok(id)) { okResponse(?int(id)) };
      case (#err(e)) { errorResponse(e) };
    };
  };

  private func handleAgentUpdate(deps : ServiceDeps, tokenNonce : Text, idStr : Text, body : Json.Json) : {
    #ok : Text;
    #err : Text;
  } {
    let agentId = switch (Nat.fromText(idStr)) {
      case (null) { return errorResponse("Invalid agent id: " # idStr) };
      case (?id) { id };
    };
    if (not validateScope(deps, tokenNonce, #agent({ id = ?agentId; access = #write }))) {
      return errorResponse("Token does not grant agent:" # idStr # ":write");
    };
    let newName = switch (Json.get(body, "name")) {
      case (?#string(n)) { ?n };
      case (_) { null };
    };
    let newModel = switch (Json.get(body, "model")) {
      case (?#string(m)) { ?m };
      case (_) { null };
    };
    switch (AgentModel.updateById(deps.agentRegistry, agentId, newName, newModel, null, null, null, null)) {
      case (#ok(_)) { okResponse(null) };
      case (#err(e)) { errorResponse(e) };
    };
  };

  // ── Event handlers ─────────────────────────────────────────────────

  private func handleEventMilestone(
    deps : ServiceDeps,
    tokenNonce : Text,
    asyncEffects : List.List<ExecutionTypes.AsyncEffect>,
    body : Json.Json,
  ) : {
    #ok : Text;
    #err : Text;
  } {
    let record = switch (ExecutionTokenService.getRecord(deps.tokenStore, tokenNonce)) {
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
    deps : ServiceDeps,
    tokenNonce : Text,
    asyncEffects : List.List<ExecutionTypes.AsyncEffect>,
    body : Json.Json,
  ) : {
    #ok : Text;
    #err : Text;
  } {
    let record = switch (ExecutionTokenService.getRecord(deps.tokenStore, tokenNonce)) {
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
    ExecutionTokenService.revoke(deps.tokenStore, tokenNonce);

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
    obj([
      ("id", int(a.id)),
      ("ownedBy", int(a.ownedBy)),
      ("category", str(categoryText)),
      ("name", str(a.config.name)),
      ("model", str(a.config.model)),
    ]);
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
    let getIntField = func(key : Text) : Int {
      switch (Json.get(body, "stats." # key)) {
        case (?#number(#int(n))) { n };
        case (?#number(#float(f))) { Float.toInt(f) };
        case (_) { 0 };
      };
    };
    let getNatField = func(key : Text) : Nat {
      let v = getIntField(key);
      if (v < 0) { 0 } else { Nat.fromInt(v) };
    };
    let model = switch (Json.get(body, "stats.model")) {
      case (?#string(m)) { m };
      case (_) { "unknown" };
    };
    {
      durationNs = getIntField("durationNs");
      llmCalls = getNatField("llmCalls");
      toolCalls = getNatField("toolCalls");
      inputTokens = getNatField("inputTokens");
      outputTokens = getNatField("outputTokens");
      model;
      rounds = getNatField("rounds");
    };
  };

  // ── Scope validation ───────────────────────────────────────────────

  private func validateScope(
    deps : ServiceDeps,
    tokenNonce : Text,
    requiredGrant : ExecutionTypes.ScopeGrant,
  ) : Bool {
    ExecutionTokenService.validate(deps.tokenStore, tokenNonce, requiredGrant);
  };

};
