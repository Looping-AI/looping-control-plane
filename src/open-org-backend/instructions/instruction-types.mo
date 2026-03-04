module {
  /// An instruction block within a layer
  public type InstructionBlock = {
    id : Text;
    content : Text;
  };

  /// Role for agent role layer selection
  public type AgentRole = {
    #orgAdmin; // org/workspace admin assistant — used by agents with category #admin
    #workspaceAdmin; // legacy: kept for backward compatibility
    #workspaceMember;
    #customAgent : { name : Text; persona : ?Text };
  };

  /// Context identifiers - service decides which to include
  public type ContextId = {
    #hasTools;
    #errorRecovery;
    #needsValueStreamSetup;
    #needsPlanCreation;
    #needsMetricsReview;
  };
};
