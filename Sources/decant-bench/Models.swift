// Throwaway benchmark models — NOT part of the shipping package.
//
// Each type conforms to BOTH Decant's @Serializable/@Deserializable AND stdlib
// Codable, with identical fields in identical declaration order so the two
// codecs read/write the same JSON shape (apples-to-apples).
//
// DecantJSON's deserializer reads struct fields POSITIONALLY (it consumes the
// key text but matches by declaration order, not by name), whereas Foundation's
// JSONEncoder emits keys in an unstable order. To make the two codecs produce
// BYTE-IDENTICAL JSON — so the same input bytes can be fed to both decoders —
// we (a) drive the encoder with `.sortedKeys` and (b) name every field so that
// ALPHABETICAL order equals DECLARATION order. Then Decant's declaration-order
// write and Codable's sorted-keys write coincide.

import Decant
import DecantMacros

// MARK: - Small flat struct

@Serializable @Deserializable
struct Small: Codable, Equatable {
  var a_id: Int32
  var b_x: Double
  var c_y: Double
  var d_active: Bool
  var e_name: String
}

// MARK: - String-heavy (clean text, no escapes — DecantJSON borrowed fast path)

@Serializable @Deserializable
struct Document: Codable, Equatable {
  var a_author: String
  var b_body: String
  var c_title: String
}

// MARK: - String-heavy with escapes (DecantJSON owned-copy escaped path)

@Serializable @Deserializable
struct EscapedDocument: Codable, Equatable {
  var a_author: String
  var b_body: String
  var c_title: String
}

// MARK: - Number-heavy

@Serializable @Deserializable
struct Numbers: Codable, Equatable {
  var a: Int64
  var b: Int64
  var c: Int64
  var d: Double
  var e: Double
  var f: Double
  var g: Int32
  var h: UInt32
}

// MARK: - Nested / recursive shape (structs within structs, a few levels)

@Serializable @Deserializable
struct Leaf: Codable, Equatable {
  var a_tag: String
  var b_value: Int32
}

@Serializable @Deserializable
struct Branch: Codable, Equatable {
  var a_leaves: Array<Leaf>
  var b_name: String
  var c_weight: Double
}

@Serializable @Deserializable
struct Tree: Codable, Equatable {
  var a_branches: Array<Branch>
  var b_root: String
  var c_version: Int32
}
