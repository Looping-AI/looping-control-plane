/// Clear Key Cache Runner
/// Clears the workspace encryption key cache, forcing fresh Schnorr-derived keys
/// on subsequent requests. Scheduled to run every 30 days.

import KeyDerivationService "../services/key-derivation-service";

module {
  public func run() : { #ok : KeyDerivationService.KeyCache; #err : Text } {
    #ok(KeyDerivationService.clearCache());
  };
};
