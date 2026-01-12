import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Error "mo:core/Error";

module {
  // ============================================
  // Types for HTTP Outcalls
  // ============================================

  public type HttpHeader = {
    name : Text;
    value : Text;
  };

  public type HttpMethod = {
    #get;
    #post;
    #head;
  };

  public type HttpRequestArgs = {
    url : Text;
    max_response_bytes : ?Nat64;
    headers : [HttpHeader];
    body : ?Blob;
    method : HttpMethod;
    transform : ?TransformContext;
    is_replicated : ?Bool;
  };

  public type TransformContext = {
    function : shared query TransformArgs -> async HttpResponsePayload;
    context : Blob;
  };

  public type TransformArgs = {
    response : HttpResponsePayload;
    context : Blob;
  };

  public type HttpResponsePayload = {
    status : Nat;
    headers : [HttpHeader];
    body : Blob;
  };

  public type ManagementCanister = actor {
    http_request : HttpRequestArgs -> async HttpResponsePayload;
  };

  // ============================================
  // Constants
  // ============================================

  /// Cost in cycles for HTTP outcall (approximate)
  public let HTTP_REQUEST_COST_CYCLES : Nat = 230_850_258_000;

  // ============================================
  // Functions
  // ============================================

  // GET request to make HTTP outcalls with custom parameters
  public func get(url : Text, headers : [HttpHeader]) : async {
    #ok : Text;
    #err : Text;
  } {
    try {
      // Get reference to management canister
      let ic : ManagementCanister = actor ("aaaaa-aa");

      // 1. Build the HTTP request args
      let http_request_args : HttpRequestArgs = {
        url;
        max_response_bytes = null;
        headers;
        body = null;
        method = #get;
        transform = null;
        is_replicated = ?false;
      };

      // 2. ADD CYCLES TO PAY FOR HTTP REQUEST
      // The IC management canister will make the HTTP request so it needs cycles
      // We attach cycles using the with cycles syntax before making the call
      let httpResponse = await (with cycles = HTTP_REQUEST_COST_CYCLES) ic.http_request(http_request_args);

      // 3. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok(decodedText);
    } catch (error : Error) {
      #err("HTTP request failed. Error Code: " # debug_show Error.code(error) # ". With message: " # Error.message(error));
    };
  };

  // POST request to make HTTP outcalls with custom parameters
  public func post(url : Text, headers : [HttpHeader], body : Text) : async {
    #ok : Text;
    #err : Text;
  } {
    try {
      // Get reference to management canister
      let ic : ManagementCanister = actor ("aaaaa-aa");

      // 1. SETUP ARGUMENTS FOR HTTP POST request
      // Use the provided body text
      let requestBody = Text.encodeUtf8(body);

      // 2. Build the HTTP request args
      let http_request_args : HttpRequestArgs = {
        url;
        max_response_bytes = null;
        headers;
        body = ?requestBody;
        method = #post;
        transform = null;
        is_replicated = ?false;
      };

      // 3. ADD CYCLES TO PAY FOR HTTP REQUEST
      // The IC management canister will make the HTTP request so it needs cycles
      // We attach cycles using the with cycles syntax before making the call
      let httpResponse = await (with cycles = HTTP_REQUEST_COST_CYCLES) ic.http_request(http_request_args);

      // 4. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok(decodedText);
    } catch (error : Error) {
      #err("HTTP request failed: " # Error.message(error));
    };
  };
};
