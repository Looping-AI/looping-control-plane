/// WorkflowCatalogService — Unit Tests (pure functions only)
///
/// Tests parseListWorkflowsResponse and filterByScopes.
/// Async refreshCatalogue is tested via integration cassettes.

import { test; expect } "mo:test";
import WorkflowCatalogService "../../../../src/control-plane-core/services/workflow-catalog-service";
import ExecutionTypes "../../../../src/control-plane-core/types/execution";

// ── parseListWorkflowsResponse ───────────────────────────────────────

let validJson : Text = "{\"catalogHash\":\"abc123\"," #
"\"descriptors\":[" #
"{\"workflowName\":\"workspace_get\"," #
"\"description\":\"Returns current workspace.\"," #
"\"parametersJsonSchema\":\"{\\\"type\\\":\\\"object\\\"}\"," #
"\"requiredScopes\":[{\"access\":\"read\",\"scope\":\"workspace\"}]," #
"\"coreDirectives\":[]}" #
"]}";

test(
  "parseListWorkflowsResponse parses valid JSON correctly",
  func() {
    switch (WorkflowCatalogService.parseListWorkflowsResponse(validJson)) {
      case (#err(_)) { expect.bool(false).isTrue() /* fail: # e */ };
      case (#ok({ catalogHash; descriptors })) {
        expect.text(catalogHash).equal("abc123");
        expect.nat(descriptors.size()).equal(1);
        expect.text(descriptors[0].workflowName).equal("workspace_get");
      };
    };
  },
);

test(
  "parseListWorkflowsResponse parses require directive",
  func() {
    let json = "{\"catalogHash\":\"h1\"," #
    "\"descriptors\":[{\"workflowName\":\"workspace_delete\"," #
    "\"description\":\"Delete.\"," #
    "\"parametersJsonSchema\":\"{}\"," #
    "\"requiredScopes\":[{\"access\":\"write\",\"scope\":\"workspace\"}]," #
    "\"coreDirectives\":[{\"require\":\"approval\"}]}]}";
    switch (WorkflowCatalogService.parseListWorkflowsResponse(json)) {
      case (#err(_)) { expect.bool(false).isTrue() };
      case (#ok(result)) {
        let descriptors = result.descriptors;
        expect.nat(descriptors[0].coreDirectives.size()).equal(1);
        switch (descriptors[0].coreDirectives[0]) {
          case (#require(val)) { expect.text(val).equal("approval") };
          case (_) { expect.bool(false).isTrue() };
        };
      };
    };
  },
);

test(
  "parseListWorkflowsResponse parses preValidation directive",
  func() {
    let json = "{\"catalogHash\":\"h2\"," #
    "\"descriptors\":[{\"workflowName\":\"workspace_set_admin_channel\"," #
    "\"description\":\"Set channel.\"," #
    "\"parametersJsonSchema\":\"{}\"," #
    "\"requiredScopes\":[{\"access\":\"write\",\"scope\":\"workspace\"}]," #
    "\"coreDirectives\":[{\"preValidation\":[{\"param\":\"channelId\",\"rule\":\"slack_channel_exists\"}]}]}]}";
    switch (WorkflowCatalogService.parseListWorkflowsResponse(json)) {
      case (#err(_)) { expect.bool(false).isTrue() };
      case (#ok(result)) {
        let descriptors = result.descriptors;
        switch (descriptors[0].coreDirectives[0]) {
          case (#preValidation(rules)) {
            expect.nat(rules.size()).equal(1);
            expect.text(rules[0].param).equal("channelId");
            expect.text(rules[0].rule).equal("slack_channel_exists");
          };
          case (_) { expect.bool(false).isTrue() };
        };
      };
    };
  },
);

test(
  "parseListWorkflowsResponse silently ignores unknown directive types",
  func() {
    let json = "{\"catalogHash\":\"h3\"," #
    "\"descriptors\":[{\"workflowName\":\"wf\"," #
    "\"description\":\"Test.\"," #
    "\"parametersJsonSchema\":\"{}\"," #
    "\"requiredScopes\":[]," #
    "\"coreDirectives\":[{\"unknownFutureDirective\":\"someValue\"}]}]}";
    switch (WorkflowCatalogService.parseListWorkflowsResponse(json)) {
      case (#err(_)) { expect.bool(false).isTrue() };
      case (#ok(result)) {
        let descriptors = result.descriptors;
        // Unknown directive dropped — coreDirectives is empty
        expect.nat(descriptors[0].coreDirectives.size()).equal(0);
      };
    };
  },
);

test(
  "parseListWorkflowsResponse ignores unknown top-level fields",
  func() {
    let json = "{\"catalogHash\":\"h4\"," #
    "\"unknownField\":\"ignored\"," #
    "\"descriptors\":[{\"workflowName\":\"wf\"," #
    "\"description\":\"Test.\"," #
    "\"parametersJsonSchema\":\"{}\"," #
    "\"requiredScopes\":[]," #
    "\"coreDirectives\":[]}]}";
    switch (WorkflowCatalogService.parseListWorkflowsResponse(json)) {
      case (#err(_)) { expect.bool(false).isTrue() };
      case (#ok(result)) {
        expect.text(result.catalogHash).equal("h4");
      };
    };
  },
);

test(
  "parseListWorkflowsResponse returns #err on malformed JSON",
  func() {
    switch (WorkflowCatalogService.parseListWorkflowsResponse("{not valid json")) {
      case (#ok(_)) { expect.bool(false).isTrue() };
      case (#err(_)) {}; // expected
    };
  },
);

test(
  "parseListWorkflowsResponse returns #err when catalogHash missing",
  func() {
    switch (WorkflowCatalogService.parseListWorkflowsResponse("{\"descriptors\":[]}")) {
      case (#ok(_)) { expect.bool(false).isTrue() };
      case (#err(_)) {}; // expected
    };
  },
);

test(
  "parseListWorkflowsResponse returns #err when descriptors missing",
  func() {
    switch (WorkflowCatalogService.parseListWorkflowsResponse("{\"catalogHash\":\"h\"}")) {
      case (#ok(_)) { expect.bool(false).isTrue() };
      case (#err(_)) {}; // expected
    };
  },
);

// ── filterByScopes ───────────────────────────────────────────────────

let workspaceReadDescriptor = {
  workflowName = "workspace_get";
  description = "Get workspace";
  parametersJsonSchema = "{}";
  requiredScopes = [{ scope = "workspace"; access = "read" }];
  coreDirectives = [];
};

let workspaceWriteDescriptor = {
  workflowName = "workspace_delete";
  description = "Delete workspace";
  parametersJsonSchema = "{}";
  requiredScopes = [{ scope = "workspace"; access = "write" }];
  coreDirectives = [];
};

let agentsReadDescriptor = {
  workflowName = "agents_list";
  description = "List agents";
  parametersJsonSchema = "{}";
  requiredScopes = [{ scope = "agents"; access = "read" }];
  coreDirectives = [];
};

let allDescriptors = [workspaceReadDescriptor, workspaceWriteDescriptor, agentsReadDescriptor];

test(
  "filterByScopes: write grant satisfies read requirement",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#workspace({ access = #write })];
    let result = WorkflowCatalogService.filterByScopes([workspaceReadDescriptor], grants);
    expect.nat(result.size()).equal(1);
  },
);

test(
  "filterByScopes: write grant satisfies write requirement",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#workspace({ access = #write })];
    let result = WorkflowCatalogService.filterByScopes([workspaceWriteDescriptor], grants);
    expect.nat(result.size()).equal(1);
  },
);

test(
  "filterByScopes: read grant satisfies read requirement",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#workspace({ access = #read })];
    let result = WorkflowCatalogService.filterByScopes([workspaceReadDescriptor], grants);
    expect.nat(result.size()).equal(1);
  },
);

test(
  "filterByScopes: read grant does NOT satisfy write requirement",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#workspace({ access = #read })];
    let result = WorkflowCatalogService.filterByScopes([workspaceWriteDescriptor], grants);
    expect.nat(result.size()).equal(0);
  },
);

test(
  "filterByScopes: #agent grant does NOT satisfy collection-level agents scope",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#agent({ id = 1; access = #read })];
    let result = WorkflowCatalogService.filterByScopes([agentsReadDescriptor], grants);
    expect.nat(result.size()).equal(0);
  },
);

test(
  "filterByScopes: #agents grant satisfies agents scope",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [#agents({ access = #read })];
    let result = WorkflowCatalogService.filterByScopes([agentsReadDescriptor], grants);
    expect.nat(result.size()).equal(1);
  },
);

test(
  "filterByScopes: no grants returns empty list",
  func() {
    let result = WorkflowCatalogService.filterByScopes(allDescriptors, []);
    expect.nat(result.size()).equal(0);
  },
);

test(
  "filterByScopes: grants matching all scopes returns all descriptors",
  func() {
    let grants : [ExecutionTypes.ScopeGrant] = [
      #workspace({ access = #write }),
      #agents({ access = #write }),
    ];
    let result = WorkflowCatalogService.filterByScopes(allDescriptors, grants);
    expect.nat(result.size()).equal(3);
  },
);

test(
  "filterByScopes: descriptor with no required scopes always passes",
  func() {
    let noScopeDescriptor = {
      workflowName = "public_op";
      description = "No scopes";
      parametersJsonSchema = "{}";
      requiredScopes = [];
      coreDirectives = [];
    };
    let result = WorkflowCatalogService.filterByScopes([noScopeDescriptor], []);
    expect.nat(result.size()).equal(1);
  },
);
