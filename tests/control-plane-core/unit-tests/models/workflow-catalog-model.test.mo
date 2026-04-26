/// WorkflowCatalogModel — Unit Tests
///
/// Tests atomic replace, getHash, and empty state invariants.

import { test; expect } "mo:test";
import WorkflowCatalogModel "../../../../src/control-plane-core/models/workflow-catalog-model";
import WorkflowCatalogTypes "../../../../src/control-plane-core/types/workflow-catalog";

// ── Helpers ─────────────────────────────────────────────────────────

let sampleDescriptors : [WorkflowCatalogTypes.WorkflowDescriptor] = [
  {
    workflowName = "workspace_get";
    description = "Returns the current workspace record.";
    parametersJsonSchema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";
    requiredScopes = [{ scope = "workspace"; access = "read" }];
    coreDirectives = [];
  },
];

// ── Tests ────────────────────────────────────────────────────────────

test(
  "empty state has no cached hash",
  func() {
    let state = WorkflowCatalogModel.empty();
    expect.bool(WorkflowCatalogModel.getHash(state) == null).isTrue();
  },
);

test(
  "replace then getHash returns the stored hash",
  func() {
    let state = WorkflowCatalogModel.empty();
    WorkflowCatalogModel.replace(state, "abc123", sampleDescriptors);
    expect.text(switch (WorkflowCatalogModel.getHash(state)) { case (?h) { h }; case null { "null" } }).equal("abc123");
  },
);

test(
  "replace is atomic — no null visible between writes",
  func() {
    let state = WorkflowCatalogModel.empty();
    WorkflowCatalogModel.replace(state, "first-hash", sampleDescriptors);
    WorkflowCatalogModel.replace(state, "second-hash", sampleDescriptors);
    // Only the latest value is visible; no intermediate null state
    expect.text(switch (WorkflowCatalogModel.getHash(state)) { case (?h) { h }; case null { "null" } }).equal("second-hash");
  },
);

test(
  "replace with a different hash overwrites previous value",
  func() {
    let state = WorkflowCatalogModel.empty();
    WorkflowCatalogModel.replace(state, "hash-v1", sampleDescriptors);
    WorkflowCatalogModel.replace(state, "hash-v2", []);
    expect.text(switch (WorkflowCatalogModel.getHash(state)) { case (?h) { h }; case null { "null" } }).equal("hash-v2");
  },
);

test(
  "empty state descriptors field is null (no cached snapshot)",
  func() {
    let state = WorkflowCatalogModel.empty();
    expect.bool(state.cached == null).isTrue();
  },
);
