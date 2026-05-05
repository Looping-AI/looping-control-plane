/// The authoritative workflow catalog contract, owned by Control Plane Core.
///
/// Core defines the shape of workflow descriptors. Internal Engine must implement
/// this contract — not the other way around. Any field, directive, or scope added
/// here becomes a requirement the engine must satisfy. Fields the engine returns
/// that are not defined here are ignored by the JSON parser, but the engine is
/// never the source of truth for what fields are allowed.
module {

  /// A single pre-validation rule applied to a named argument before dispatch.
  public type PreValidationRule = {
    param : Text;
    rule : Text;
  };

  /// A directive Core must act on before dispatching this workflow.
  ///
  /// #require("approval") — suspend the turn and prompt the user for confirmation.
  /// #preValidation(rules) — validate one or more args against external systems before dispatch.
  ///
  /// Unknown variants parsed from a future engine version are dropped silently (forward compat).
  public type CoreDirective = {
    #require : Text;
    #preValidation : [PreValidationRule];
  };

  public type RequiredScope = {
    scope : Text;
    access : Text;
  };

  public type WorkflowDescriptor = {
    workflowName : Text;
    description : Text;
    /// Raw JSON schema string — forwarded directly to the LLM tool definition.
    parametersJsonSchema : Text;
    requiredScopes : [RequiredScope];
    coreDirectives : [CoreDirective];
  };

};
