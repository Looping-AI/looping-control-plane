module {

  public type CoreApi = actor {
    executionApi : shared ({ #get; #post; #delete }, Text, Text) -> async {
      #ok : Text;
      #err : Text;
    };
  };

};
