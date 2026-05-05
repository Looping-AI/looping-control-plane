import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

/// Hashing utilities: SHA-256 over text, returned as a lowercase hex string.
module {

  private let hexAlphabet : [Char] = [
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
  ];

  private func byteToHex(b : Nat8) : Text {
    let n = Nat8.toNat(b);
    Text.fromChar(hexAlphabet[n / 16]) # Text.fromChar(hexAlphabet[n % 16]);
  };

  private func blobToHex(b : Blob) : Text {
    Array.foldLeft<Nat8, Text>(
      Blob.toArray(b),
      "",
      func(acc : Text, byte : Nat8) : Text { acc # byteToHex(byte) },
    );
  };

  /// Compute a SHA-256 hash of a UTF-8 string.
  /// Returns a 64-character lowercase hex string.
  public func sha256Hex(text : Text) : Text {
    let hashBlob = Sha256.fromBlob(#sha256, Text.encodeUtf8(text));
    blobToHex(hashBlob);
  };

};
