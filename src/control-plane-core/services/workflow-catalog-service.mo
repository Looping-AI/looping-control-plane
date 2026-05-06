import Array "mo:core/Array";
import Error "mo:core/Error";
import List "mo:core/List";
import Json "mo:json";
import WorkflowCatalogTypes "../types/workflow-catalog";
import WorkflowCatalogModel "../models/workflow-catalog-model";
import WorkflowTypes "../types/workflow";
import InternalEngine "../../internal-engine/main";

/// Workflow catalog service — fetching, parsing, and scope filtering.
///
/// Pure functions (`parseListWorkflowsResponse`, `filterByScopes`) are unit-testable
/// without any async infrastructure.
module {

  // ── JSON parsing ───────────────────────────────────────────────────

  /// Parse the JSON response from `engine.listWorkflows()`.
  /// Returns #err(message) if the JSON is malformed or missing required fields.
  /// Unknown `coreDirective` types and unknown top-level fields are silently ignored.
  public func parseListWorkflowsResponse(
    json : Text
  ) : {
    #ok : {
      catalogHash : Text;
      descriptors : [WorkflowCatalogTypes.WorkflowDescriptor];
    };
    #err : Text;
  } {
    let parsed = switch (Json.parse(json)) {
      case (#err(_)) { return #err("Invalid JSON in listWorkflows response") };
      case (#ok(v)) { v };
    };

    let catalogHash = switch (Json.get(parsed, "catalogHash")) {
      case (?#string(h)) { h };
      case (_) { return #err("Missing or invalid 'catalogHash' field") };
    };

    let descriptors = switch (Json.get(parsed, "descriptors")) {
      case (?#array(items)) {
        let result = List.empty<WorkflowCatalogTypes.WorkflowDescriptor>();
        for (item in items.vals()) {
          switch (parseDescriptor(item)) {
            case (#ok(d)) { List.add(result, d) };
            case (#err(e)) { return #err("Failed to parse descriptor: " # e) };
          };
        };
        List.toArray(result);
      };
      case (_) { return #err("Missing or invalid 'descriptors' field") };
    };

    #ok({ catalogHash; descriptors });
  };

  private func parseDescriptor(
    json : Json.Json
  ) : { #ok : WorkflowCatalogTypes.WorkflowDescriptor; #err : Text } {
    let workflowName = switch (Json.get(json, "workflowName")) {
      case (?#string(s)) { s };
      case (_) { return #err("Missing 'workflowName'") };
    };
    let description = switch (Json.get(json, "description")) {
      case (?#string(s)) { s };
      case (_) { return #err("Missing 'description' in " # workflowName) };
    };
    let parametersJsonSchema = switch (Json.get(json, "parametersJsonSchema")) {
      case (?#string(s)) { s };
      case (_) {
        return #err("Missing 'parametersJsonSchema' in " # workflowName);
      };
    };

    let requiredScopes = switch (Json.get(json, "requiredScopes")) {
      case (?#array(items)) {
        let result = List.empty<WorkflowCatalogTypes.RequiredScope>();
        for (item in items.vals()) {
          switch (parseRequiredScope(item)) {
            case (#ok(s)) { List.add(result, s) };
            case (#err(e)) { return #err(e # " in " # workflowName) };
          };
        };
        List.toArray(result);
      };
      case (_) { return #err("Missing 'requiredScopes' in " # workflowName) };
    };

    let coreDirectives = switch (Json.get(json, "coreDirectives")) {
      case (?#array(items)) {
        let result = List.empty<WorkflowCatalogTypes.CoreDirective>();
        for (item in items.vals()) {
          switch (parseDirective(item)) {
            case (?d) { List.add(result, d) };
            case (null) {}; // unknown directive type — silently skip for forward compat
          };
        };
        List.toArray(result);
      };
      case (_) { return #err("Missing 'coreDirectives' in " # workflowName) };
    };

    #ok({
      workflowName;
      description;
      parametersJsonSchema;
      requiredScopes;
      coreDirectives;
    });
  };

  private func parseRequiredScope(
    json : Json.Json
  ) : { #ok : WorkflowCatalogTypes.RequiredScope; #err : Text } {
    let scope = switch (Json.get(json, "scope")) {
      case (?#string(s)) { s };
      case (_) { return #err("Missing 'scope' in requiredScope") };
    };
    let access = switch (Json.get(json, "access")) {
      case (?#string(a)) { a };
      case (_) { return #err("Missing 'access' in requiredScope") };
    };
    #ok({ scope; access });
  };

  private func parseDirective(json : Json.Json) : ?WorkflowCatalogTypes.CoreDirective {
    // #require directive: {"require": "..."}
    switch (Json.get(json, "require")) {
      case (?#string(val)) { return ?#require(val) };
      case (_) {};
    };
    // #preValidation directive: {"preValidation": [{param, rule}, ...]}
    switch (Json.get(json, "preValidation")) {
      case (?#array(items)) {
        let rules = List.empty<WorkflowCatalogTypes.PreValidationRule>();
        for (item in items.vals()) {
          switch (Json.get(item, "param"), Json.get(item, "rule")) {
            case (?#string(param), ?#string(rule)) {
              List.add(rules, { param; rule });
            };
            case _ {}; // skip malformed rules silently
          };
        };
        return ?#preValidation(List.toArray(rules));
      };
      case (_) {};
    };
    null; // unknown directive type — drop for forward compat
  };

  // ── Scope filtering ────────────────────────────────────────────────

  /// Pure filter: keep descriptors whose every `requiredScope` is satisfied
  /// by at least one of the provided `scopeGrants`.
  ///
  /// Satisfaction rules:
  ///   #write grant satisfies both "read" and "write" requirements.
  ///   #read grant satisfies only "read" requirements.
  ///   #agent (per-agent) grant does NOT satisfy the collection-level "agents" scope.
  public func filterByScopes(
    descriptors : [WorkflowCatalogTypes.WorkflowDescriptor],
    scopeGrants : [WorkflowTypes.ScopeGrant],
  ) : [WorkflowCatalogTypes.WorkflowDescriptor] {
    Array.filter<WorkflowCatalogTypes.WorkflowDescriptor>(
      descriptors,
      func(d : WorkflowCatalogTypes.WorkflowDescriptor) : Bool {
        allScopesGranted(d.requiredScopes, scopeGrants);
      },
    );
  };

  private func allScopesGranted(
    required : [WorkflowCatalogTypes.RequiredScope],
    grants : [WorkflowTypes.ScopeGrant],
  ) : Bool {
    for (req in required.vals()) {
      if (not scopeSatisfied(req, grants)) { return false };
    };
    true;
  };

  private func scopeSatisfied(
    req : WorkflowCatalogTypes.RequiredScope,
    grants : [WorkflowTypes.ScopeGrant],
  ) : Bool {
    for (grant in grants.vals()) {
      if (grantSatisfiesScope(grant, req.scope, req.access)) { return true };
    };
    false;
  };

  private func grantSatisfiesScope(
    grant : WorkflowTypes.ScopeGrant,
    scope : Text,
    accessNeeded : Text,
  ) : Bool {
    switch (grant) {
      case (#workspace({ access })) {
        scope == "workspace" and accessSufficient(access, accessNeeded);
      };
      case (#agents({ access })) {
        scope == "agents" and accessSufficient(access, accessNeeded);
      };
      case (#agent(_)) {
        false; // per-agent grant does not satisfy collection-level "agents" scope
      };
      case (#slackQueue({ access })) {
        scope == "slackQueue" and accessSufficient(access, accessNeeded);
      };
      case (#session({ access })) {
        scope == "session" and accessSufficient(access, accessNeeded);
      };
    };
  };

  private func accessSufficient(
    granted : WorkflowTypes.ScopeAccess,
    needed : Text,
  ) : Bool {
    switch (granted, needed) {
      case (#write, "write") { true };
      case (#write, "read") { true }; // write satisfies both "read" and "write"
      case (#write, _) { false };
      case (#read, "read") { true };
      case (#read, _) { false };
    };
  };

  // ── Async refresh ──────────────────────────────────────────────────

  /// Fetch the current catalog from the engine, parse it, and atomically
  /// replace the cache. On any failure (network error or parse error) the
  /// existing cache is left unchanged — no partial writes.
  public func refreshCatalog(
    state : WorkflowCatalogModel.CatalogState,
    engine : InternalEngine.InternalEngine,
  ) : async { #ok; #err : Text } {
    let response = try {
      await engine.listWorkflows();
    } catch (e) {
      return #err("listWorkflows() call failed: " # Error.message(e));
    };

    let json = switch (response) {
      case (#err(e)) {
        return #err("Engine returned error from listWorkflows(): " # e);
      };
      case (#ok(text)) { text };
    };

    switch (parseListWorkflowsResponse(json)) {
      case (#err(e)) { #err("Failed to parse catalog response: " # e) };
      case (#ok({ catalogHash; descriptors })) {
        WorkflowCatalogModel.replace(state, catalogHash, descriptors);
        #ok;
      };
    };
  };

};
