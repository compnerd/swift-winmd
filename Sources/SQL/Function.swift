// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A named scalar function — a per-row computation over typed values.
///
/// A scalar function takes its arguments already evaluated to typed `Value`s
/// (the engine evaluates each argument expression against the row first) and
/// returns one `Value`. This is the signature the per-dialect decode functions
/// (`guid`, `ret_type`, `span_type`, …) take: each is a pure mapping from cell
/// values to a cell value, registered by name and called from a projection or a
/// predicate. A function that cannot map its arguments throws `SQLError`.
public typealias Scalar =
    @Sendable (_ arguments: Array<Value>) throws(SQLError) -> Value

/// The catalog of named scalar functions the engine resolves a call against.
///
/// A `SELECT` projection or predicate may call a function by name; the engine
/// looks it up here and applies it to its evaluated arguments. `Routines` is
/// escapable, immutable data — a `[name: Scalar]` map built once and threaded
/// through compilation and execution beside the catalog. A name the routines do
/// not know is `SQLError.function` at evaluation. This is the one non-data tier
/// of synthesis: composing existing functions is free, but a new decode
/// primitive is a registered closure.
public struct Routines: Sendable {
  /// The registered functions, keyed by their case-folded (lower-cased) name.
  private let functions: Dictionary<String, Scalar>

  /// Empty routines — every call faults until a function is registered.
  public init() {
    self.functions = [:]
  }

  /// Routines over a `name → function` map; each name folds to lower case so a
  /// call resolves by the SQL identifier rule. Two names differing only by case
  /// merge (the later-sorting original spelling wins) instead of trapping.
  public init(_ functions: Dictionary<String, Scalar>) {
    self.functions = functions.sorted { $0.key < $1.key }
      .reduce(into: Dictionary<String, Scalar>()) {
        $0[$1.key.lowercased()] = $1.value
      }
  }

  /// The function named `name`, folded to lower case like every other SQL
  /// identifier, or `nil` if neither a built-in nor a registered function bears
  /// it. An engine built-in resolves AHEAD of a registered function of the same
  /// name: an unqualified scalar call can never shadow a built-in. (A future
  /// PATH / search-order mechanism — à la DB2 or PostgreSQL — would let a
  /// qualified call reach a user's redefinition.)
  public func function(named name: String) -> Scalar? {
    Routines.builtins[name.lowercased()] ?? functions[name.lowercased()]
  }

  /// A copy of these routines with `function` bound to `name` (folded to lower
  /// case), the binding shadowing any existing one.
  public func registering(_ name: String, _ function: @escaping Scalar)
      -> Routines {
    var functions = self.functions
    functions[name.lowercased()] = function
    return Routines(functions)
  }

  /// These routines overlaid with `other`'s — a caller composing two routine
  /// sources (e.g. a target-language spec's UDFs and a data source's domain
  /// UDFs). A name `other` also binds shadows this one's; names are already
  /// case-folded on both sides.
  public func merging(_ other: Routines) -> Routines {
    Routines(functions.merging(other.functions) { _, last in last })
  }

  /// The engine's built-in scalar functions, available to every `Routines` —
  /// even the empty one — and resolved ahead of a registered function of the
  /// same name (see `function(named:)`), so an unqualified call always reaches
  /// the built-in. `BITAND` is the portable, standards-compliant spelling
  /// (Oracle's) of a bitwise AND, an operation ISO SQL and this grammar
  /// otherwise lack; it is a built-in so any dialect gets it without registering
  /// a closure.
  private static let builtins: Dictionary<String, Scalar> = ["bitand": bitand]

  /// `BITAND(x, y)` — the bitwise AND of two integers. A NULL argument yields
  /// NULL (SQL null propagation); the wrong argument count or a non-integer
  /// argument is `SQLError.argument` (a function-argument fault — not
  /// `SQLError.arity`, which is the UNION column-count mismatch).
  private static let bitand: Scalar = { arguments in
    guard arguments.count == 2 else {
      throw .argument("BITAND takes two arguments")
    }
    if case .null = arguments[0] { return .null }
    if case .null = arguments[1] { return .null }
    guard case let .integer(x) = arguments[0],
        case let .integer(y) = arguments[1] else {
      throw .argument("BITAND requires integer arguments")
    }
    return .integer(x & y)
  }
}

extension Routines: ExpressibleByDictionaryLiteral {
  /// Builds routines from a `name: function` dictionary literal — an empty
  /// literal `[:]` is the empty routines, `["upper": …]` registers inline.
  /// A repeated key keeps the last; `init(_:)` then case-folds the names.
  public init(dictionaryLiteral elements: (String, Scalar)...) {
    self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
