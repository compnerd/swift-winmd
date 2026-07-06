// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A registered scalar routine — a per-row computation over evaluated arguments
/// paired with its declared signature.
///
/// A routine takes its arguments already evaluated to typed `Value`s (the
/// engine evaluates each argument expression against the row first) and returns
/// one `Value`; it is CALLED as a function — `routine(arguments)`. It
/// declares the type of each positional `parameter` — the count is the arity —
/// and the result `returns` type, both read to TYPE a `f(...)` call WITHOUT
/// running it: the result-schema walk (`Scope.derive(_:_:)`) types a call by
/// `returns`, the type-check walk (`Scope.validate(_:_:)`) validates each
/// argument against `parameters`, and the `INFORMATION_SCHEMA` `data_type` a
/// view's `GUID(...)` column reports from `returns`.
///
/// A routine is one of two kinds. A NATIVE routine is a Swift closure — the
/// shape the per-dialect decode routines (`guid`, `ret_type`, `span_type`, …)
/// take, each a pure mapping from cell values to a cell value, registered by
/// name and called from a projection or a predicate. A DEFINED routine —
/// `CREATE FUNCTION name(p TYPE, …) RETURNS TYPE AS expression` — carries a SQL
/// scalar `Expression` over its named parameters, lowered ONCE at registration
/// to a `Term` addressing the parameters by slot (parameter `i` is slot `i`); a
/// call binds its evaluated arguments into a record and evaluates that term. A
/// defined body EARLY-BINDS the routines its own calls name: it captures the
/// `Routines` visible at its definition and resolves its nested calls through
/// THAT environment, not the map in scope at call time — the ISO subject-
/// routine rule, under which a body's routine references are fixed when it is
/// defined. A routine that cannot map its arguments throws `SQLError`; one that
/// does not declare a result type is `.integer`, the engine's exact-numeric
/// default.
public struct Routine: Sendable {
  /// A routine's implementation — a native Swift closure or a defined SQL
  /// expression body.
  private enum Body: Sendable {
    /// A native routine: a Swift closure over the evaluated arguments.
    case native(@Sendable (Array<Value>) throws(SQLError) -> Value)
    /// A defined routine: the body `Expression` lowered to a `Term` over the
    /// parameter slots (parameter `i` at slot `i`), evaluated per call against
    /// a record of the bound arguments. It carries the captured `Routines` its
    /// body was validated against at registration — its nested calls resolve
    /// through this environment (early binding), not the call-time map.
    case defined(Term, Routines)
  }

  /// The declared type of each positional argument, in order — its count the
  /// routine's arity. The static type-check validates a call against this: a
  /// wrong argument count or a definitively-wrong argument type is rejected
  /// before a schema is published (see `Scope`'s `call`).
  public let parameters: Array<ValueType>

  /// The declared result type, read to type a call statically.
  public let returns: ValueType

  /// The routine's implementation.
  private let body: Body

  public init(returns: ValueType = .integer, parameters: Array<ValueType>,
              _ compute: @escaping @Sendable (Array<Value>)
                  throws(SQLError) -> Value) {
    self.parameters = parameters
    self.returns = returns
    self.body = .native(compute)
  }

  /// A DEFINED routine — the `CREATE FUNCTION name(names[i] parameters[i], …)
  /// RETURNS returns AS expression` body, its scalar `Expression` lowered to a
  /// `Term` over the parameters (parameter `i` at slot `i`) so a call evaluates
  /// it against a record of the bound argument values.
  ///
  /// The body's column references resolve against the parameter `names`, in
  /// order — a name the parameters do not declare is `SQLError.column`, as any
  /// unresolved reference is. An aggregate in the body faults `SQLError`
  /// (`term` rejects it), the same way an aggregate in a projection expression
  /// does. `names.count == parameters.count` — each parameter names its type.
  ///
  /// The declared `returns` is also ENFORCED here, statically: the body's type
  /// is validated over the parameter schema and must equal `returns`, else
  /// `SQLError.argument` — the same case the type-check reports an argument
  /// contract violation with. This uses the FAULTING type-check path, not the
  /// non-faulting derive: derive would type an unknown call by the `.integer`
  /// default and let `f() RETURNS INTEGER AS g()` pass while `g` is
  /// unregistered, then return `g`'s later-declared type. The faulting path
  /// instead rejects an unresolved call with `SQLError.function`. The check is
  /// exact-equality, mirroring the argument type-check (`Scope.call`), which
  /// treats integer and double as distinct rather than numerically
  /// interchangeable. A run-time NULL is not a type: it propagates through any
  /// declared type, so a body that yields NULL on a row is unaffected — only
  /// the validated static type is contracted.
  ///
  /// The passed `routines` are the environment the body EARLY-BINDS: it is both
  /// what the returns validation resolves the body's own calls against AND what
  /// the `.defined` case captures, so a nested call evaluates against exactly
  /// the map it was typed against — the two are consistent by construction.
  internal init(returns: ValueType, parameters: Array<ValueType>,
                names: Array<String>, body: Expression,
                _ routines: Routines) throws(SQLError) {
    // A body's inputs are its declared parameters, not query bindings: it is
    // validated over the parameter schema and later evaluated against ONLY the
    // argument record, so a `:parameter` reference (reachable through a `CASE`
    // guard) would always be UNBOUND at call time — the caller's `bindings`
    // never reach a routine body — and silently pick the wrong branch. Reject
    // a `.bound` anywhere in the body at registration rather than lowering it.
    guard !body.bound else {
      throw .argument("the body cannot reference a query parameter")
    }
    let schema = Schema(width: names.count, extent: names.count,
                        names: names, types: parameters, virtuals: [])
    let scope = Scope([(Relation(name: ""), schema)])
    let derived = try scope.validate(body, routines)
    guard derived == returns else {
      throw .argument("the body yields \(derived.domain), not the declared "
                          + "\(returns.domain)")
    }
    self.parameters = parameters
    self.returns = returns
    self.body =
        try .defined(schema.term(body, in: Relation(name: ""), routines),
                     routines)
  }

  /// Computes the cell value for the evaluated `arguments`, resolving a defined
  /// body's own scalar calls through the environment it CAPTURED at definition.
  ///
  /// A native routine runs its closure. A defined routine binds `arguments`
  /// into a record — argument `i` at slot `i`, matching the parameter its body
  /// was lowered against — and evaluates its lowered term against it, so the
  /// body's parameter references read the bound values. The term's own nested
  /// calls resolve through the captured `Routines` (early binding), so a callee
  /// later redefined for queries does not change what this body computes.
  ///
  /// A defined routine ENFORCES its arity AND its argument types here — the run
  /// path does not type-check a call before evaluating it, so a defined body
  /// dispatched over the wrong argument shape would otherwise misbehave:
  /// reading slot `i` of a record short an argument would trap, and a
  /// wrong-typed argument would flow through the body unchecked, letting `id(n
  /// INTEGER) AS n` called over a TEXT column return a `.text` value against an
  /// INTEGER contract. The argument count must equal its `parameters` count,
  /// else `SQLError.argument` (the case a native routine like `BITAND` reports
  /// a bad count with); and each argument's type must equal the declared
  /// parameter's, else the same `SQLError.argument`. A NULL argument is EXEMPT:
  /// NULL is not a type, it propagates through any declared type — exactly as
  /// `BITAND` returns NULL on a NULL argument and the static type-check
  /// (`Scope.call`) admits a nullable value of the declared type. A native
  /// routine self-checks both its arity and its argument types inside its
  /// closure (with its own messages), so its dispatch is left untouched.
  public func callAsFunction(_ arguments: Array<Value>)
      throws(SQLError) -> Value {
    switch body {
    case let .native(compute):
      return try compute(arguments)
    case let .defined(term, routines):
      guard arguments.count == parameters.count else {
        throw .argument("takes \(parameters.count) arguments")
      }
      for (argument, expected) in zip(arguments, parameters)
          where !argument.matches(expected) {
        throw .argument("requires \(expected.domain) arguments")
      }
      return try evaluate(term, Record(arguments), routines)
    }
  }
}

extension Value {
  /// Whether this value satisfies a parameter declared as `type` — the run-time
  /// counterpart of the static argument type-check (`Scope.call`). A `null`
  /// matches ANY declared type: NULL is not a type, it propagates through the
  /// body exactly as a native routine (`BITAND`) returns NULL on a NULL
  /// argument. A non-NULL value matches only its own type, so a `.text` value
  /// bound to an `.integer` parameter does not.
  fileprivate func matches(_ type: ValueType) -> Bool {
    switch self {
    case .null: true
    case .integer: type == .integer
    case .double: type == .double
    case .text: type == .text
    case .boolean: type == .boolean
    case .blob: type == .blob
    }
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

  /// A copy of these routines with a routine computing `compute`, accepting
  /// `parameters` (default none), and returning `returns` (default `.integer`)
  /// bound to `name` (folded to lower case), the binding shadowing any existing
  /// one.
  //
  // `SQL.Value` is spelled in full here and in `bitand`: `Routines` conforms to
  // `ExpressibleByDictionaryLiteral`, whose associated `Value` is the literal's
  // element `Routine`, so an unqualified `Value` inside `Routines` names that
  // element, not the engine cell the routine computes.
  public func registering(_ name: String, returns: ValueType = .integer,
                          parameters: Array<ValueType> = [],
                          _ compute: @escaping @Sendable (Array<SQL.Value>)
                              throws(SQLError) -> SQL.Value) -> Routines {
    var functions = self.functions
    functions[name.lowercased()] =
        Routine(returns: returns, parameters: parameters, compute)
    return Routines(functions)
  }

  /// A copy of these routines with the DEFINED `function` bound to `name`
  /// (folded to lower case), the binding shadowing any existing one — the
  /// registration a consumer performs for a parsed `CREATE FUNCTION`, mirroring
  /// a catalog registering a `CREATE VIEW`'s `View`.
  ///
  /// The function's body is lowered to a term over its parameters HERE, so a
  /// body naming a parameter the function does not declare faults
  /// `SQLError.column` at registration — the moment a `CREATE FUNCTION` binds —
  /// rather than at each later call, exactly as a native routine's signature is
  /// fixed at registration. The body's derived type must equal the declared
  /// `returns`, else `SQLError.argument` (see `Routine`'s defined initializer).
  ///
  /// Two parameters colliding under case-insensitive resolution are rejected
  /// HERE with `SQLError.duplicate` — the later spelling — exactly as the
  /// parser rejects them: a lowered body resolves a name to the FIRST matching
  /// parameter (`Schema.ordinal(of:)`), so a duplicate would leave the second
  /// slot unreachable yet still required by the arity. The parser guards the
  /// grammar path; this guards a `Function` a caller CONSTRUCTS directly and
  /// registers, so neither path admits a duplicate.
  ///
  /// The body EARLY-BINDS the routines its own calls name: it captures the
  /// standard prelude OVERLAID with these routines — `Routines.standard`
  /// merged under the map before this registration, the SAME precedence the
  /// public `run`/`columns` compose a query's routines with (the prelude is
  /// the base, a caller registration shadows a like-named prelude routine) —
  /// and resolves its nested calls through that captured environment at run
  /// time, the ISO subject-routine rule (a body's routine references are fixed
  /// when it is defined). Bringing the prelude into the capture is what lets a
  /// body call a built-in: `lowbit(n) AS BITAND(n, 1)` resolves `BITAND` here
  /// exactly as an ordinary `SELECT` would, rather than faulting at
  /// registration for a routine the query path can see. A body naming its OWN
  /// registration `name` is well-defined, not recursion: `f() AS f() + 1`
  /// REPLACING a prior `f` captures the OLD `f`, so it computes `f_old() + 1`
  /// and terminates. With NO prior `f` and no prelude `f`, the captured map
  /// lacks `f`, so the body's call is unresolved and the returns validation
  /// above faults `SQLError.function` — the unregistered-callee case, not a
  /// self-reference one. Query-level resolution is UNCHANGED: a top-level
  /// `SELECT f()` still resolves `f` to the LATEST binding (a later
  /// registration shadows an earlier one); capture governs only a body's
  /// INTERNAL calls, not which `f` a query reaches.
  public func registering(_ name: String, _ function: Function)
      throws(SQLError) -> Routines {
    var seen = Set<String>()
    for parameter in function.parameters
        where !seen.insert(parameter.name.lowercased()).inserted {
      throw .duplicate(parameter.name)
    }
    var functions = self.functions
    functions[name.lowercased()] =
        try Routine(returns: function.returns,
                    parameters: function.parameters.map(\.type),
                    names: function.parameters.map(\.name),
                    body: function.body, Routines.standard.merging(self))
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
  public static let standard: Routines =
      ["bitand": Routine(parameters: [.integer, .integer], bitand)]

  /// `BITAND(x, y)` — the bitwise AND of two integers. A NULL argument yields
  /// NULL (SQL null propagation); the wrong argument count or a non-integer
  /// argument is `SQLError.argument` (a function-argument fault — not
  /// `SQLError.arity`, which is the UNION column-count mismatch). Its declared
  /// `[.integer, .integer]` contract is what the static type-check validates a
  /// call against, mirroring these run-time faults.
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
  /// Builds routines from a `name: Routine` dictionary literal, so every
  /// registered routine declares its full signature — its `parameters` and
  /// `returns` — inline: `["bitand": Routine(parameters: [.integer, .integer],
  /// bitand)]`. An empty literal `[:]` is the empty routines; a repeated key
  /// keeps the last, and `init(_:)` case-folds the names.
  public init(dictionaryLiteral elements: (String, Routine)...) {
    self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
