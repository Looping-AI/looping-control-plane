import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Error "mo:core/Error";
import Nat64 "mo:core/Nat64";
import Float "mo:core/Float";
import Int "mo:core/Int";

module {
  // ============================================
  // HTTP Outcalls Module
  // ============================================
  //
  // SECURITY CONSIDERATIONS:
  // - All HTTP outcalls are first made as encrypted intercanister calls to the IC management canister
  // - If the target URL uses HTTPS, both headers and body are encrypted end-to-end and visible only to the destination server
  // - Sensitive data such as API keys, authorization tokens, and authentication credentials passed in headers
  //   are safe from intermediaries when using HTTPS URLs
  // - Always use HTTPS URLs (not HTTP) when transmitting sensitive data through these functions

  // ============================================
  // Types
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

  /// Maximum response bytes allowed for HTTP outcalls (2 MB hard limit)
  /// Requests exceeding this will result in an error.
  public let MAX_RESPONSE_BYTES : Nat64 = 2_000_000;

  /// Typical subnet size (13 nodes on application subnets)
  public let SUBNET_SIZE : Nat = 13;

  /// Safety multiplier for cycle calculations to account for uncertainty
  /// Multiply by this factor to avoid rejections; excess cycles are refunded
  public let SAFETY_MULTIPLIER : Float = 1.5;

  // ============================================
  // Helper Functions
  // ============================================

  /// Calculates the total size of an HTTP request in bytes
  ///
  /// Formula: request_size = url.len + header_len + body.len
  /// where header_len = header_1.name + header_1.value + ... + header_n.name + header_n.value
  ///
  /// # Parameters
  /// - `url` : The request URL
  /// - `headers` : Array of HTTP headers
  /// - `body` : Optional request body
  ///
  /// # Returns
  /// Total request size in bytes
  public func calculateRequestBytes(
    url : Text,
    headers : [HttpHeader],
    body : ?Blob,
  ) : Nat {
    var totalBytes = Text.size(url);

    // Add headers size (name + value for each header)
    for (header in headers.vals()) {
      totalBytes += Text.size(header.name);
      totalBytes += Text.size(header.value);
    };

    // Add body size
    switch (body) {
      case (null) {};
      case (?bodyBlob) {
        totalBytes += Blob.size(bodyBlob);
      };
    };

    totalBytes;
  };

  /// Calculates the total cycles needed for an HTTPS outcall using the official IC formula
  ///
  /// Documentation: https://docs.internetcomputer.org/references/cycles-cost-formulas
  ///
  /// Official formula:
  /// total_fee = base_fee + size_fee
  /// base_fee = (3_000_000 + 60_000 * n) * n
  /// size_fee = (400 * request_bytes + 800 * max_response_bytes) * n
  /// where n = number of nodes in the subnet
  ///
  /// The result is multiplied by a safety factor to handle uncertainty and subnet variations.
  /// Excess cycles are automatically refunded.
  ///
  /// # Parameters
  /// - `requestBytes` : Total request size in bytes (URL + headers + body)
  ///
  /// # Returns
  /// Cycles needed for the HTTP outcall request
  public func calculateHttpOutcallCycles(
    requestBytes : Nat
  ) : Nat {
    let n = SUBNET_SIZE;

    // Calculate base fee: (3_000_000 + 60_000 * n) * n
    let baseFee = (3_000_000 + 60_000 * n) * n;

    // Calculate size fee: (400 * request_bytes + 800 * max_response_bytes) * n
    let sizeFee = (400 * requestBytes + 800 * Nat64.toNat(MAX_RESPONSE_BYTES)) * n;

    // Total fee with safety multiplier
    let totalFeeBeforeMultiplier = baseFee + sizeFee;
    let totalFee = Int.toNat(Float.toInt(Float.fromInt(totalFeeBeforeMultiplier) * SAFETY_MULTIPLIER));

    totalFee;
  };

  /// Performs a GET HTTP request with custom headers
  ///
  /// # Parameters
  /// - `url` : The target URL. Use HTTPS for secure transmission of sensitive data
  /// - `headers` : Custom HTTP headers. Sensitive headers (e.g., Authorization tokens) are encrypted
  ///              end-to-end when using HTTPS URLs
  ///
  /// # Returns
  /// - `#ok(statusCode, response)` : Tuple of HTTP status code and response body as plain text
  /// - `#err(message)` : Error message if the request fails
  public func get(url : Text, headers : [HttpHeader]) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    try {
      // Get reference to management canister
      let ic : ManagementCanister = actor ("aaaaa-aa");

      // 1. Calculate cycles needed based on request size
      let requestBytes = calculateRequestBytes(url, headers, null);
      let cyclesNeeded = calculateHttpOutcallCycles(requestBytes);

      // 2. Build the HTTP request args
      let http_request_args : HttpRequestArgs = {
        url;
        max_response_bytes = null;
        headers;
        body = null;
        method = #get;
        transform = null;
        is_replicated = ?false;
      };

      // 3. ADD CYCLES TO PAY FOR HTTP REQUEST
      // The IC management canister will make the HTTP request so it needs cycles
      // We attach cycles using the with cycles syntax before making the call
      // Cycles are calculated dynamically based on request size
      let httpResponse = await (with cycles = cyclesNeeded) ic.http_request(http_request_args);

      // 5. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok((httpResponse.status, decodedText));
    } catch (error : Error) {
      #err("HTTP request trapped. Error Code: " # debug_show Error.code(error) # ". Message: " # Error.message(error));
    };
  };

  /// Performs a POST HTTP request with custom headers and body
  ///
  /// # Parameters
  /// - `url` : The target URL. Use HTTPS for secure transmission of sensitive data
  /// - `headers` : Custom HTTP headers. Sensitive headers (e.g., Authorization tokens) are encrypted
  ///              end-to-end when using HTTPS URLs
  /// - `body` : The request body to send. Encrypted end-to-end when using HTTPS URLs
  ///
  /// # Returns
  /// - `#ok(statusCode, response)` : Tuple of HTTP status code and response body as plain text
  /// - `#err(message)` : Error message if the request fails
  public func post(url : Text, headers : [HttpHeader], body : Text) : async {
    #ok : (Nat, Text);
    #err : Text;
  } {
    try {
      // Get reference to management canister
      let ic : ManagementCanister = actor ("aaaaa-aa");

      // 1. SETUP ARGUMENTS FOR HTTP POST request
      // Use the provided body text
      let requestBody = Text.encodeUtf8(body);

      // 2. Calculate cycles needed based on request size (including body)
      let requestBytes = calculateRequestBytes(url, headers, ?requestBody);
      let cyclesNeeded = calculateHttpOutcallCycles(requestBytes);

      // 3. Build the HTTP request args
      let http_request_args : HttpRequestArgs = {
        url;
        max_response_bytes = null;
        headers;
        body = ?requestBody;
        method = #post;
        transform = null;
        is_replicated = ?false;
      };

      // 4. ADD CYCLES TO PAY FOR HTTP REQUEST
      // The IC management canister will make the HTTP request so it needs cycles
      // We attach cycles using the with cycles syntax before making the call
      // Cycles are calculated dynamically based on request size
      let httpResponse = await (with cycles = cyclesNeeded) ic.http_request(http_request_args);

      // 5. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok((httpResponse.status, decodedText));
    } catch (error : Error) {
      #err("HTTP request trapped. Error Code: " # debug_show Error.code(error) # ". Message: " # Error.message(error));
    };
  };
};
