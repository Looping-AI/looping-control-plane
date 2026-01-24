import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import KeyDerivationService "../../../../src/open-org-backend/services/key-derivation-service";

// Test workspace IDs
let workspaceId1 : Nat = 1;
let workspaceId2 : Nat = 2;

suite(
  "KeyDerivationService",
  func() {
    test(
      "getSchnorrKeyName returns correct key name for local environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#local);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_LOCAL);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for test environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#test);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_LOCAL);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for staging environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#staging);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_TEST);
      },
    );

    test(
      "getSchnorrKeyName returns correct key name for production environment",
      func() {
        let keyName = KeyDerivationService.getSchnorrKeyName(#production);
        expect.text(keyName).equal(KeyDerivationService.KEY_NAME_PROD);
      },
    );

    test(
      "clearCache returns an empty cache",
      func() {
        let cache = KeyDerivationService.clearCache();
        let size = KeyDerivationService.getCacheSize(cache);
        expect.nat(size).equal(0);
      },
    );

    test(
      "getCacheSize returns correct count after adding entries",
      func() {
        let cache = Map.empty<Nat, [Nat8]>();
        let size = KeyDerivationService.getCacheSize(cache);
        expect.nat(size).equal(0);

        let testKey1 : [Nat8] = [0x00, 0x01, 0x02, 0x03];
        let testKey2 : [Nat8] = [0x04, 0x05, 0x06, 0x07];

        Map.add(cache, Nat.compare, workspaceId1, testKey1);
        expect.nat(KeyDerivationService.getCacheSize(cache)).equal(1);

        Map.add(cache, Nat.compare, workspaceId2, testKey2);
        expect.nat(KeyDerivationService.getCacheSize(cache)).equal(2);
      },
    );
  },
);
