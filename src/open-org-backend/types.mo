module {
  /// Environment configuration for the bot-agent application
  /// Determines which Schnorr key to use for key derivation and other environment-specific behavior
  public type Environment = {
    #local;
    #test;
    #staging;
    #production;
  };

  /// LLM Provider
  public type LlmProvider = {
    #openai;
    #llmcanister;
    #groq;
  };

  /// Goal Status
  public type GoalStatus = {
    #Inactive;
    #Active;
    #Archived;
  };

  /// Goal with title, description, status, timestamps, and priority
  public type Goal = {
    title : Text;
    description : Text;
    status : GoalStatus;
    createdAt : Int;
    createdBy : Principal;
    priorityIndex : Nat;
  };
};
