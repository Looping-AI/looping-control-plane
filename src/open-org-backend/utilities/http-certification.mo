/// Minimal HTTP response certification module for ICP.
///
/// Provides "skip certification" (no_certification) support for HTTP query responses,
/// so the IC HTTP gateway accepts them without full response verification.
///
/// Uses only `ic-certification` (MerkleTree) + `sha2` — no other external dependencies.
///
/// Usage:
///   1. Store:    `var certStore = HttpCertification.initStore();`
///   2. Certify:  call `HttpCertification.certifySkipPath(certStore, "/")` from an update context
///   3. Recert:   call `HttpCertification.recertify(certStore)` in `postupgrade`
///   4. Headers:  append `HttpCertification.getSkipCertificationHeaders(certStore, "/")` to query response

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import CertifiedData "mo:core/CertifiedData";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import MerkleTree "mo:ic-certification/MerkleTree";
import SHA256 "mo:sha2/Sha256";

module {

  // ============================================
  // Public Types
  // ============================================

  /// Stable store for the certification Merkle tree.
  /// Declare as a `var` in a `persistent actor` — it survives upgrades automatically.
  public type CertStore = {
    var tree : MerkleTree.Tree;
  };

  // ============================================
  // Constants
  // ============================================

  /// The CEL expression that tells the HTTP gateway to skip verification.
  let SKIP_CERT_EXPR : Text = "default_certification ( ValidationArgs { no_certification: Empty { } } )";

  // ============================================
  // Public API
  // ============================================

  /// Create a new, empty certification store.
  public func initStore() : CertStore {
    { var tree = MerkleTree.empty() };
  };

  /// Register a URL path as "skip certification" in the Merkle tree and
  /// commit the root hash via `CertifiedData.set`.
  ///
  /// **Must be called from an update context** (actor init, `postupgrade`, or an update method).
  /// Call once per path you want to serve from `http_request` without full verification.
  public func certifySkipPath(store : CertStore, url : Text) {
    let textExprPath = buildTextExprPath(url);
    let blobExprPath = Array.map<Text, Blob>(textExprPath, Text.encodeUtf8);
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));

    // For no_certification both request_hash and response_hash are empty blobs
    let fullPath = appendBlobs(blobExprPath, [exprHash, "", ""]);
    store.tree := MerkleTree.put(store.tree, fullPath, "");
    CertifiedData.set(MerkleTree.treeHash(store.tree));
  };

  /// Re-commit the existing tree's root hash after a canister upgrade.
  ///
  /// The IC clears `CertifiedData` on upgrade, but a `persistent actor` preserves
  /// the `CertStore` variable. This function re-sets the root hash without
  /// rebuilding the tree.
  ///
  /// **Must be called from `postupgrade`.**
  public func recertify(store : CertStore) {
    CertifiedData.set(MerkleTree.treeHash(store.tree));
  };

  /// Return the two certification headers required by the IC HTTP gateway
  /// for a "skip certification" response at the given URL.
  ///
  /// Call this from `http_request` (query) and append the result to your response headers.
  /// Returns an empty array if the system certificate is unavailable
  /// (e.g. called from an update context instead of a query).
  public func getSkipCertificationHeaders(store : CertStore, url : Text) : [(Text, Text)] {
    let textExprPath = buildTextExprPath(url);
    let blobExprPath = Array.map<Text, Blob>(textExprPath, Text.encodeUtf8);
    let exprHash = SHA256.fromBlob(#sha256, Text.encodeUtf8(SKIP_CERT_EXPR));
    let fullPath = appendBlobs(blobExprPath, [exprHash, "", ""]);

    // Build witness proving this path exists in the tree
    let witness = MerkleTree.reveal(store.tree, fullPath);
    let encodedWitness = MerkleTree.encodeWitness(witness);

    // System certificate — only available in query calls
    let certificate = switch (CertifiedData.getCertificate()) {
      case (?cert) cert;
      case null return [];
    };

    // CBOR-encode the text expression path for the header
    let encodedExprPath = cborEncodeTextArray(textExprPath);

    let icCertValue = "certificate=:" # base64(certificate) # ":, " #
    "tree=:" # base64(encodedWitness) # ":, " #
    "version=2, " #
    "expr_path=:" # base64(encodedExprPath) # ":";

    [
      ("ic-certificate", icCertValue),
      ("ic-certificateexpression", SKIP_CERT_EXPR),
    ];
  };

  // ============================================
  // Internal — Expression Path
  // ============================================

  /// Build the V2 text expression path for a URL (exact-match variant).
  ///
  /// Examples:
  ///   "/" → ["http_expr", "", "<$>"]
  ///   "/health" → ["http_expr", "health", "<$>"]
  ///   "/api/status" → ["http_expr", "api", "status", "<$>"]
  func buildTextExprPath(url : Text) : [Text] {
    let segments : [Text] = if (url == "" or url == "/") {
      [""];
    } else {
      let parts = Text.split(url, #char '/');
      ignore parts.next(); // skip leading empty segment from "/"
      Iter.toArray(parts);
    };

    let size : Nat = segments.size() + 2; // "http_expr" + segments + "<$>"
    let lastIdx : Nat = size - 1 : Nat;
    Array.tabulate<Text>(
      size,
      func(i : Nat) : Text {
        if (i == 0) "http_expr" else if (i < lastIdx) segments[i - 1 : Nat] else "<$>";
      },
    );
  };

  // ============================================
  // Internal — Minimal CBOR encoder (text arrays)
  // ============================================

  /// Encode a [Text] as CBOR: self-describing tag + array of text strings.
  func cborEncodeTextArray(arr : [Text]) : Blob {
    let encodedTexts = Array.map<Text, Blob>(arr, Text.encodeUtf8);

    // 1. Calculate total byte count
    var totalSize = 3; // self-describing tag: D9 D9 F7
    totalSize += cborHeaderLen(arr.size()); // array header
    for (encoded in encodedTexts.vals()) {
      totalSize += cborHeaderLen(encoded.size()); // text string header
      totalSize += encoded.size(); // text string body
    };

    // 2. Build flat byte array using a mutable array
    let result = Array.toVarArray<Nat8>(Array.repeat<Nat8>(0, totalSize));
    var pos = 0;

    // Self-describing CBOR tag (55799)
    result[pos] := 0xD9;
    pos += 1;
    result[pos] := 0xD9;
    pos += 1;
    result[pos] := 0xF7;
    pos += 1;

    // Array header (major type 4)
    pos := writeCborHeader(result, pos, 4 : Nat8, arr.size());

    // Each text string (major type 3)
    for (encoded in encodedTexts.vals()) {
      pos := writeCborHeader(result, pos, 3 : Nat8, encoded.size());
      for (b in encoded.vals()) {
        result[pos] := b;
        pos += 1;
      };
    };

    Blob.fromArray(Array.fromVarArray(result));
  };

  /// Write a CBOR major-type header into a mutable byte array. Returns updated position.
  func writeCborHeader(buf : [var Nat8], pos : Nat, majorType : Nat8, len : Nat) : Nat {
    let mt : Nat8 = majorType * 32;
    if (len < 24) {
      buf[pos] := mt + Nat8.fromNat(len);
      pos + 1;
    } else if (len < 256) {
      buf[pos] := mt + 24;
      buf[pos + 1] := Nat8.fromNat(len);
      pos + 2;
    } else {
      // len < 65536 — sufficient for any realistic expression path
      buf[pos] := mt + 25;
      buf[pos + 1] := Nat8.fromNat(len / 256);
      buf[pos + 2] := Nat8.fromNat(len % 256);
      pos + 3;
    };
  };

  /// Byte length of a CBOR major-type header for a given payload length.
  func cborHeaderLen(len : Nat) : Nat {
    if (len < 24) 1 else if (len < 256) 2 else 3;
  };

  // ============================================
  // Internal — Base64 encoder (standard, with padding)
  // ============================================

  let BASE64_ALPHABET : [Char] = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
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
    '+',
    '/',
  ];

  func base64(data : Blob) : Text {
    let bytes = Blob.toArray(data);
    let len = bytes.size();
    if (len == 0) return "";

    let outputLen = ((len + 2) / 3) * 4;

    let chars = Array.tabulate<Char>(
      outputLen,
      func(ci : Nat) : Char {
        let group = ci / 4;
        let pos = ci % 4;
        let bi = group * 3;

        // Padding positions
        if (pos == 2 and bi + 1 >= len) return '=';
        if (pos == 3 and bi + 2 >= len) return '=';

        let b0 = Nat8.toNat(bytes[bi]);
        let b1 = if (bi + 1 < len) Nat8.toNat(bytes[bi + 1]) else 0;
        let b2 = if (bi + 2 < len) Nat8.toNat(bytes[bi + 2]) else 0;

        let index = switch pos {
          case 0 { b0 / 4 };
          case 1 { (b0 % 4) * 16 + b1 / 16 };
          case 2 { (b1 % 16) * 4 + b2 / 64 };
          case _ { b2 % 64 };
        };

        BASE64_ALPHABET[index];
      },
    );

    Text.fromIter(chars.vals());
  };

  // ============================================
  // Internal — Helpers
  // ============================================

  /// Concatenate two Blob arrays.
  func appendBlobs(a : [Blob], b : [Blob]) : [Blob] {
    let aLen = a.size();
    Array.tabulate<Blob>(
      aLen + b.size(),
      func(i : Nat) : Blob {
        if (i < aLen) a[i] else b[i - aLen];
      },
    );
  };
};
