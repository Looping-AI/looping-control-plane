import Text "mo:core/Text";
import Error "mo:core/Error";
import IC "mo:ic/Types";
import ICCall "mo:ic/Call";

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

  public type HttpHeader = IC.HttpHeader;

  // ============================================
  // Helper Functions
  // ============================================

  /// Validates and normalizes a URL, ensuring it has a valid http/s scheme
  ///
  /// If the URL doesn't start with "http://" or "https://", this function
  /// automatically prepends "https://" to make it a valid HTTPS URL.
  ///
  /// # Parameters
  /// - `url` : The URL to validate and normalize
  ///
  /// # Returns
  /// A valid URL with http/s scheme
  public func validateAndNormalizeUrl(url : Text) : Text {
    if (Text.startsWith(url, #text "https://") or Text.startsWith(url, #text "http://")) {
      url;
    } else {
      "https://" # url;
    };
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
      // 1. Validate and normalize the URL
      let validatedUrl = validateAndNormalizeUrl(url);

      // 2. Build the HTTP request args
      let http_request_args : IC.HttpRequestArgs = {
        url = validatedUrl;
        max_response_bytes = null;
        headers;
        body = null;
        method = #get;
        transform = null;
        is_replicated = ?false;
      };

      // 3. Make the HTTP request via the IC management canister.
      // Cycles are calculated automatically by ICCall.httpRequest using the IC cost formula.
      let httpResponse = await ICCall.httpRequest(http_request_args);

      // 4. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok((httpResponse.status, decodedText));
    } catch (error : Error) {
      #err("HTTP request trapped. Error Code: " # debug_show Error.code(error) # ". Message: " # Error.message(error) # ".");
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
      // 1. Validate and normalize the URL
      let validatedUrl = validateAndNormalizeUrl(url);

      // 2. Encode the body
      let requestBody = Text.encodeUtf8(body);

      // 3. Build the HTTP request args
      let http_request_args : IC.HttpRequestArgs = {
        url = validatedUrl;
        max_response_bytes = null;
        headers;
        body = ?requestBody;
        method = #post;
        transform = null;
        is_replicated = ?false;
      };

      // 4. Make the HTTP request via the IC management canister.
      // Cycles are calculated automatically by ICCall.httpRequest using the IC cost formula.
      let httpResponse = await ICCall.httpRequest(http_request_args);

      // 5. DECODE THE RESPONSE
      let decodedText : Text = switch (Text.decodeUtf8(httpResponse.body)) {
        case (null) { "No value returned" };
        case (?y) { y };
      };

      #ok((httpResponse.status, decodedText));
    } catch (error : Error) {
      #err("HTTP request trapped. Error Code: " # debug_show Error.code(error) # ". Message: " # Error.message(error) # ".");
    };
  };
};
