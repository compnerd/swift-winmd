// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// Imports ONLY DecantMacros — never Decant directly — so this target fails
// to build if the derive layer stops re-exporting the `Decant` core. A macro
// expansion references `Decant.Serializable`/`Decant.Serializer` (and the
// deserialize equivalents) in this scope; without the re-export their members
// are not visible here and the conformance does not compile.
import DecantMacros

@Serializable
@Deserializable
struct Probe {
  let x: Int
  let y: Int
}

// A tuple stored binding destructures into its components, so the generated
// conformance writes and reads each and the synthesized memberwise init —
// flattened to `TupleProbe(a:x:y:b:)` — reconstructs them. That this compiles
// is the guarantee: a syntactic derive that skipped the tuple would emit too
// few fields and a mismatched initializer.
@Serializable
@Deserializable
struct TupleProbe {
  var a: Int
  var (x, y): (Int, Int)
  var b: Int
}

// A nested tuple binding flattens the same way — `NestedProbe(x:y:z:)`.
@Serializable
@Deserializable
struct NestedProbe {
  var (x, (y, z)): (Int, (Int, Int))
}

// Stored properties named exactly for the macro's own introduced locals — the
// serialize sub-serializer (`structure`), the consumed `serializer`, and the
// `inout deserializer` parameter. Without hygiene the generated `field(…)`
// operand or the decoded `let` would resolve to those introduced names, so this
// FAILS to compile: `field("structure", structure)` would pass the
// sub-serializer (not `Serializable`) and `let deserializer = …` would shadow
// the parameter the structure-close reads. With `makeUniqueName` locals and
// `self.`-qualified reads it derives, compiles, and does not miscompile.
@Serializable
@Deserializable
struct HygieneProbe {
  var structure: Int
  var serializer: Int
  var deserializer: Int
}

// A type-level member — `static let`/`static var`, and the `class` spelling on
// the reference-count-free struct is still type level — is NOT an instance
// stored property and NOT a memberwise-init parameter. The derive must skip it:
// were `version`/`shared` collected, serialize would emit `self.version` and
// deserialize would pass an argument the memberwise init `StaticProbe(x:y:)`
// has no parameter for, so this FAILS to compile. That it derives is the guard.
@Serializable
@Deserializable
struct StaticProbe {
  static let version = 1
  nonisolated(unsafe) static var shared = 0
  let x: Int
  var y: Int
}

// A field whose type is inferred from its initializer (`count`, no written
// annotation). The read is emitted in the memberwise-init argument position, so
// the init parameter supplies `decode`'s result type; without that context the
// generic `decode()` has nothing to infer against and this FAILS to type-check.
@Serializable
@Deserializable
struct InferredProbe {
  var count = 0
  let name: String
}

// An untyped tuple leaf — `(x, y)` inferred `(1, 2)` — flattens to the same
// init-argument reads, so each leaf's type comes from its `InferredTupleProbe`
// parameter. It compiles for the same reason `InferredProbe` does.
@Serializable
@Deserializable
struct InferredTupleProbe {
  var (x, y) = (1, 2)
}

// The shapes the diagnostics for `lazy` and initialized `let` must NOT
// over-reject: an uninitialized `let` is a REQUIRED memberwise parameter, an
// initialized `var` is a DEFAULTED one, and an observed stored `var` stays a
// parameter too. All three remain instance stored properties in the
// synthesized memberwise init, so the derive collects each and this compiles;
// were the rejection too broad, `MemberwiseProbe(x:y:z:)` would lose a
// parameter and the generated init call would fail to type-check.
@Serializable
@Deserializable
struct MemberwiseProbe {
  let x: Int
  var y = 0
  var z = 0 {
    didSet {}
  }
}
