import WorkflowCatalogTypes "../types/workflow-catalog";

/// Catalog cache state for Core.
///
/// Holds the last successfully fetched workflow catalog from the engine.
/// The cache is either fully populated (hash + descriptors) or absent — there
/// is no "stale" intermediate state. Atomic `replace` ensures this invariant.
module {

  public type CatalogState = {
    var cached : ?{
      catalogHash : Text;
      descriptors : [WorkflowCatalogTypes.WorkflowDescriptor];
    };
  };

  public func empty() : CatalogState {
    { var cached = null };
  };

  /// Atomically replace the cached catalog.
  /// The old value is never visible between clear and write.
  public func replace(
    state : CatalogState,
    catalogHash : Text,
    descriptors : [WorkflowCatalogTypes.WorkflowDescriptor],
  ) {
    state.cached := ?{ catalogHash; descriptors };
  };

  /// Returns the cached hash, or null if the cache is empty.
  public func getHash(state : CatalogState) : ?Text {
    switch (state.cached) {
      case (null) { null };
      case (?c) { ?c.catalogHash };
    };
  };

};
