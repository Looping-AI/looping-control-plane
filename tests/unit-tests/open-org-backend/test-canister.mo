import HttpWrapper "../../../src/open-org-backend/wrappers/http-wrapper";
import GroqWrapper "../../../src/open-org-backend/wrappers/groq-wrapper";

// ============================================
// Test Canister
// ============================================

// IMPORTANT:
// Never add this canister to dfx or deploy it

shared ({ caller = parent }) persistent actor class TestCanister() {
  public shared ({ caller }) func httpGet(url : Text, headers : [HttpWrapper.HttpHeader]) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.get(url, headers);
  };

  public shared ({ caller }) func httpPost(url : Text, headers : [HttpWrapper.HttpHeader], body : Text) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    assert caller == parent;
    await HttpWrapper.post(url, headers, body);
  };

  public shared ({ caller }) func groqChat(apiKey : Text, userMessage : Text, model : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.chat(apiKey, userMessage, model);
  };

  public shared ({ caller }) func groqReason(
    apiKey : Text,
    input : Text,
    model : Text,
    trackId : GroqWrapper.TrackId,
    instructions : ?Text,
    reasoningEffort : ?GroqWrapper.ReasoningEffort,
  ) : async {
    #ok : Text;
    #err : Text;
  } {
    assert caller == parent;
    await GroqWrapper.reason(apiKey, input, model, trackId, instructions, reasoningEffort);
  };
};
