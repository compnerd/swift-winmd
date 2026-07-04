// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A registered scalar routine — a per-row computation over evaluated arguments
/// paired with its declared result type.
///
/// A routine takes its arguments already evaluated to typed `Value`s (the
/// engine evaluates each argument expression against the row first) and returns
/// one `Value`; it is CALLED as a function — `routine(arguments)`. It declares
/// the result `returns` type, read to TYPE a `f(...)` call WITHOUT running it:
/// the result-schema walk (`Scope.type(of:)`) and the `INFORMATION_SCHEMA`
/// `data_type` a view's `GUID(...)` column reports. This is the shape the
/// per-dialect decode routines (`guid`, `ret_type`, `span_type`, …) take — each
/// a pure mapping from cell values to a cell value, registered by name and
/// called from a projection or a predicate. A routine that cannot map its
/// arguments throws `SQLError`; one that does not declare a result type is
/// `.integer`, the engine's exact-numeric default.
public struct Routine: Sendable {
  /// The declared result type, read to type a call statically.
  public let returns: ValueType

  /// The per-row computation over evaluated arguments.
  private let compute: @Sendable (Array<Value>) throws(SQLError) -> Value

  public init(returns: ValueType = .integer,
              _ compute: @escaping @Sendable (Array<Value>)
                  throws(SQLError) -> Value) {
    self.returns = returns
    self.compute = compute
  }

  /// Computes the cell value for the evaluated `arguments`.
  public func callAsFunction(_ arguments: Array<Value>)
      throws(SQLError) -> Value {
    try compute(arguments)
  }
}

/// The catalog of named scalar routines the engine resolves a call against.
///
/// A `SELECT` projection or predicate may call a routine by name; the engine
/// looks it up here and applies it to its evaluated arguments. `Routines` is
/// escapable, immutable data — a `[name: Routine]` map built once and threaded
/// through compilation and execution beside the catalog. A name the routines do
/// not know is `SQLError.function` at evaluation. This is the one non-data tier
/// of synthesis: composing existing routines is free, but a new decode
/// primitive is a registered closure.
public struct Routines: Sendable {
  /// The registered routines, keyed by their case-folded (lower-cased) name.
  private let functions: Dictionary<String, Routine>

  /// Empty routines — every call faults until a routine is registered.
  public init() {
    self.functions = [:]
  }

  /// Routines over a `name → routine` map; each name folds to lower case so a
  /// call resolves by the SQL identifier rule. Two names differing only by case
  /// merge (the later-sorting original spelling wins) instead of trapping.
  public init(_ functions: Dictionary<String, Routine>) {
    self.functions = functions.sorted { $0.key < $1.key }
      .reduce(into: Dictionary<String, Routine>()) {
        $0[$1.key.lowercased()] = $1.value
      }
  }

  /// The routine `name` names, folded to lower case like every other SQL
  /// identifier, or `nil` if no registered routine bears it. There is a single
  /// flat map with no privileged tier: a prelude routine (`Routines.standard`)
  /// and a caller-registered one resolve through the same lookup, so a later
  /// registration shadows an earlier binding of the same name — the house rule
  /// the resolver already follows (a view shadows a table, a CTE shadows a
  /// view). (A future PATH / search-order mechanism — à la DB2 or PostgreSQL —
  /// would let a qualified call reach a specific one across schemas.)
  public subscript(_ name: String) -> Routine? {
    functions[name.lowercased()]
  }

  /// The declared result type of every registered routine, keyed by its
  /// case-folded name — the map the result-schema walk (`Scope.type(of:)`) and
  /// the `INFORMATION_SCHEMA` view-column typing read to type a `f(...)` call.
  public var returns: Dictionary<String, ValueType> {
    functions.mapValues(\.returns)
  }

  /// A copy of these routines with a routine computing `compute` and returning
  /// `returns` (default `.integer`) bound to `name` (folded to lower case), the
  /// binding shadowing any existing one.
  //
  // `SQL.Value` is spelled in full here and in `bitand`: `Routines` conforms to
  // `ExpressibleByDictionaryLiteral`, whose associated `Value` is the literal's
  // element closure type, so an unqualified `Value` inside `Routines` names
  // that closure, not the engine cell the routine computes.
  public func registering(_ name: String, returns: ValueType = .integer,
                          _ compute: @escaping @Sendable (Array<SQL.Value>)
                              throws(SQLError) -> SQL.Value) -> Routines {
    var functions = self.functions
    functions[name.lowercased()] = Routine(returns: returns, compute)
    return Routines(functions)
  }

  /// These routines overlaid with `other`'s — a caller composing two routine
  /// sources (e.g. a target-language spec's UDFs and a data source's domain
  /// UDFs). A name `other` also binds shadows this one's; names are already
  /// case-folded on both sides.
  public func merging(_ other: Routines) -> Routines {
    Routines(functions.merging(other.functions) { _, last in last })
  }

  /// The standard-library prelude — the routines the engine ships, seeded into
  /// the flat registry at the public entry points so a query reaches them
  /// without a caller registering a closure. They are ordinary entries in the
  /// same map as any registered routine, not a privileged tier, so a caller MAY
  /// shadow one (see `subscript(_:)`). Its lone member is `BITAND`, the
  /// portable, standards-compliant spelling (Oracle's) of a bitwise AND — an
  /// operation ISO SQL and this grammar otherwise lack; it returns an integer.
  public static let standard: Routines = ["bitand": bitand]

  /// `BITAND(x, y)` — the bitwise AND of two integers. A NULL argument yields
  /// NULL (SQL null propagation); the wrong argument count or a non-integer
  /// argument is `SQLError.argument` (a function-argument fault — not
  /// `SQLError.arity`, which is the UNION column-count mismatch).
  private static func bitand(_ arguments: Array<SQL.Value>)
      throws(SQLError) -> SQL.Value {
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
  /// Builds routines from a `name: closure` dictionary literal — the value is a
  /// BARE closure, so `["upper": { … }]` reads unchanged for a client that
  /// declares no return type, the routine defaulting to a `.integer` result.
  /// `registering(_:returns:_:)` declares another return type. An empty literal
  /// `[:]` is the empty routines; a repeated key keeps the last, and `init(_:)`
  /// case-folds the names.
  //
  // The value is spelled as a closure (not a `Routine`) so the historical
  // bare-closure registration keeps type-checking; this closure IS the
  // associated `Value`, so the full `SQL.Value` spelling names the engine cell.
  public init(dictionaryLiteral elements:
                  (String, @Sendable (Array<SQL.Value>)
                      throws(SQLError) -> SQL.Value)...) {
    self.init(Dictionary(
        elements.map { ($0.0, Routine(returns: .integer, $0.1)) },
        uniquingKeysWith: { _, last in last }))
  }
}
