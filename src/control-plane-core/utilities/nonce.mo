import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Sha256 "mo:sha2/Sha256";
import Hmac "hmac";

module {

  /// Produce an unpredictable 64-char hex nonce:
  ///   SHA256(salt || counter-bytes(8) || timestamp-bytes(8))
  public func make(salt : Blob, counter : Nat, now : Int) : Text {
    let input = List.empty<Nat8>();
    for (byte in Blob.toArray(salt).vals()) { List.add(input, byte) };
    for (byte in natToBytes8(counter).vals()) { List.add(input, byte) };
    for (byte in natToBytes8(Int.abs(now)).vals()) { List.add(input, byte) };
    Hmac.bytesToHex(Sha256.fromArray(#sha256, List.toArray(input)));
  };

  /// Encode a Nat as 8 big-endian bytes.
  private func natToBytes8(n : Nat) : [Nat8] {
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        Nat8.fromNat((n / (256 ** (7 - i))) % 256);
      },
    );
  };
};
