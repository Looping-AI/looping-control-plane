import { test; suite; expect } "mo:test";
import Hmac "../../../../src/open-org-backend/utilities/hmac";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

// RFC 4231 Test Vectors for HMAC-SHA256
// https://www.rfc-editor.org/rfc/rfc4231

suite(
  "HMAC-SHA256",
  func() {

    suite(
      "compute",
      func() {

        test(
          "RFC 4231 Test Case 1: short key (20 bytes) with 'Hi There'",
          func() {
            // Key = 0x0b repeated 20 times
            let key = Array.repeat<Nat8>(0x0b, 20);

            // Message = "Hi There"
            let message : [Nat8] = [0x48, 0x69, 0x20, 0x54, 0x68, 0x65, 0x72, 0x65];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
            expect.text(hex).equal("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
          },
        );

        test(
          "RFC 4231 Test Case 2: short key 'Jefe' with 'what do ya want for nothing?'",
          func() {
            // Key = "Jefe"
            let key : [Nat8] = [0x4a, 0x65, 0x66, 0x65];

            // Message = "what do ya want for nothing?"
            let message : [Nat8] = [
              0x77,
              0x68,
              0x61,
              0x74,
              0x20,
              0x64,
              0x6f,
              0x20,
              0x79,
              0x61,
              0x20,
              0x77,
              0x61,
              0x6e,
              0x74,
              0x20,
              0x66,
              0x6f,
              0x72,
              0x20,
              0x6e,
              0x6f,
              0x74,
              0x68,
              0x69,
              0x6e,
              0x67,
              0x3f,
            ];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
            expect.text(hex).equal("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
          },
        );

        test(
          "RFC 4231 Test Case 3: 20-byte key of 0xaa with 20-byte message of 0xdd",
          func() {
            let key = Array.repeat<Nat8>(0xaa, 20);
            let message = Array.repeat<Nat8>(0xdd, 50);

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe
            expect.text(hex).equal("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
          },
        );

        test(
          "RFC 4231 Test Case 4: 25-byte key with 50-byte message of 0xcd",
          func() {
            // Key = 0x01..0x19 (25 bytes)
            let key = Array.tabulate<Nat8>(25, func(i : Nat) : Nat8 { Nat8.fromNat(i + 1) });
            let message = Array.repeat<Nat8>(0xcd, 50);

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b
            expect.text(hex).equal("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
          },
        );

        test(
          "RFC 4231 Test Case 6: key longer than block size (131 bytes)",
          func() {
            // Key = 0xaa repeated 131 times (longer than 64-byte block size — key gets hashed first)
            let key = Array.repeat<Nat8>(0xaa, 131);

            // Message = "Test Using Larger Than Block-Size Key - Hash Key First"
            let message : [Nat8] = [
              0x54,
              0x65,
              0x73,
              0x74,
              0x20,
              0x55,
              0x73,
              0x69,
              0x6e,
              0x67,
              0x20,
              0x4c,
              0x61,
              0x72,
              0x67,
              0x65,
              0x72,
              0x20,
              0x54,
              0x68,
              0x61,
              0x6e,
              0x20,
              0x42,
              0x6c,
              0x6f,
              0x63,
              0x6b,
              0x2d,
              0x53,
              0x69,
              0x7a,
              0x65,
              0x20,
              0x4b,
              0x65,
              0x79,
              0x20,
              0x2d,
              0x20,
              0x48,
              0x61,
              0x73,
              0x68,
              0x20,
              0x4b,
              0x65,
              0x79,
              0x20,
              0x46,
              0x69,
              0x72,
              0x73,
              0x74,
            ];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54
            expect.text(hex).equal("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
          },
        );

        test(
          "RFC 4231 Test Case 7: large key + large message (both > block size)",
          func() {
            // Key = 0xaa repeated 131 times
            let key = Array.repeat<Nat8>(0xaa, 131);

            // Message = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
            let message : [Nat8] = [
              0x54,
              0x68,
              0x69,
              0x73,
              0x20,
              0x69,
              0x73,
              0x20,
              0x61,
              0x20,
              0x74,
              0x65,
              0x73,
              0x74,
              0x20,
              0x75,
              0x73,
              0x69,
              0x6e,
              0x67,
              0x20,
              0x61,
              0x20,
              0x6c,
              0x61,
              0x72,
              0x67,
              0x65,
              0x72,
              0x20,
              0x74,
              0x68,
              0x61,
              0x6e,
              0x20,
              0x62,
              0x6c,
              0x6f,
              0x63,
              0x6b,
              0x2d,
              0x73,
              0x69,
              0x7a,
              0x65,
              0x20,
              0x6b,
              0x65,
              0x79,
              0x20,
              0x61,
              0x6e,
              0x64,
              0x20,
              0x61,
              0x20,
              0x6c,
              0x61,
              0x72,
              0x67,
              0x65,
              0x72,
              0x20,
              0x74,
              0x68,
              0x61,
              0x6e,
              0x20,
              0x62,
              0x6c,
              0x6f,
              0x63,
              0x6b,
              0x2d,
              0x73,
              0x69,
              0x7a,
              0x65,
              0x20,
              0x64,
              0x61,
              0x74,
              0x61,
              0x2e,
              0x20,
              0x54,
              0x68,
              0x65,
              0x20,
              0x6b,
              0x65,
              0x79,
              0x20,
              0x6e,
              0x65,
              0x65,
              0x64,
              0x73,
              0x20,
              0x74,
              0x6f,
              0x20,
              0x62,
              0x65,
              0x20,
              0x68,
              0x61,
              0x73,
              0x68,
              0x65,
              0x64,
              0x20,
              0x62,
              0x65,
              0x66,
              0x6f,
              0x72,
              0x65,
              0x20,
              0x62,
              0x65,
              0x69,
              0x6e,
              0x67,
              0x20,
              0x75,
              0x73,
              0x65,
              0x64,
              0x20,
              0x62,
              0x79,
              0x20,
              0x74,
              0x68,
              0x65,
              0x20,
              0x48,
              0x4d,
              0x41,
              0x43,
              0x20,
              0x61,
              0x6c,
              0x67,
              0x6f,
              0x72,
              0x69,
              0x74,
              0x68,
              0x6d,
              0x2e,
            ];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2
            expect.text(hex).equal("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2");
          },
        );

        test(
          "key exactly 64 bytes (block size) — verified vector",
          func() {
            // Key = 0x01 repeated 64 times
            let key = Array.repeat<Nat8>(0x01, 64);
            // Message = single byte 0x12
            let message : [Nat8] = [0x12];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 9fc5fd7acf75bf2125220240293bd8221d72a25ffb5bfb397ee1a2a00df7a1ad
            expect.text(hex).equal("9fc5fd7acf75bf2125220240293bd8221d72a25ffb5bfb397ee1a2a00df7a1ad");
          },
        );

        test(
          "key 65 bytes (just over block size) — triggers key hashing",
          func() {
            // Key = 0x01 repeated 65 times (one byte over block size, so key gets hashed)
            let key = Array.repeat<Nat8>(0x01, 65);
            // Message = single byte 0x12
            let message : [Nat8] = [0x12];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: 4a8ac5b5f14061a2ed19ea9ac716b3c2c27343ac4dc52e42fabb9b1ab019d335
            expect.text(hex).equal("4a8ac5b5f14061a2ed19ea9ac716b3c2c27343ac4dc52e42fabb9b1ab019d335");
          },
        );

        test(
          "empty message produces valid 32-byte HMAC",
          func() {
            let key : [Nat8] = [0x01, 0x02, 0x03, 0x04];
            let message : [Nat8] = [];

            let result = Hmac.compute(key, message);

            expect.nat(Blob.toArray(result).size()).equal(32);
          },
        );

        test(
          "empty key and empty message — verified vector",
          func() {
            let key : [Nat8] = [];
            let message : [Nat8] = [];

            let result = Hmac.compute(key, message);
            let hex = Hmac.bytesToHex(result);

            // Expected: b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
            expect.text(hex).equal("b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
          },
        );

        test(
          "different keys produce different HMACs",
          func() {
            let key1 : [Nat8] = [0x01, 0x02, 0x03, 0x04];
            let key2 : [Nat8] = [0x05, 0x06, 0x07, 0x08];
            let message : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

            let result1 = Hmac.bytesToHex(Hmac.compute(key1, message));
            let result2 = Hmac.bytesToHex(Hmac.compute(key2, message));

            expect.bool(result1 == result2).isFalse();
          },
        );

        test(
          "different messages produce different HMACs",
          func() {
            let key : [Nat8] = [0x01, 0x02, 0x03, 0x04];
            let msg1 : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]; // "Hello"
            let msg2 : [Nat8] = [0x57, 0x6F, 0x72, 0x6C, 0x64]; // "World"

            let result1 = Hmac.bytesToHex(Hmac.compute(key, msg1));
            let result2 = Hmac.bytesToHex(Hmac.compute(key, msg2));

            expect.bool(result1 == result2).isFalse();
          },
        );
      },
    );

    suite(
      "bytesToHex",
      func() {

        test(
          "converts bytes to lowercase hex string",
          func() {
            let bytes = Blob.fromArray([0x48, 0x65, 0x6C, 0x6C, 0x6F]);
            let hex = Hmac.bytesToHex(bytes);

            expect.text(hex).equal("48656c6c6f");
          },
        );

        test(
          "handles empty blob",
          func() {
            let bytes = Blob.fromArray([]);
            let hex = Hmac.bytesToHex(bytes);

            expect.text(hex).equal("");
          },
        );

        test(
          "handles 0x00 and 0xff boundary values",
          func() {
            let bytes = Blob.fromArray([0x00, 0xFF]);
            let hex = Hmac.bytesToHex(bytes);

            expect.text(hex).equal("00ff");
          },
        );
      },
    );

  },
);
