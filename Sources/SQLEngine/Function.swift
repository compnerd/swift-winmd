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
///
/// A routine also declares whether it is DETERMINISTIC — ISO SQL's
/// `DETERMINISTIC` / `NOT DETERMINISTIC` characteristic: a deterministic
/// routine returns the same value for the same arguments every time and has no
/// side effect, so the engine may execute it at COMPILE time to fold a
/// row-independent call (see `Resolve`'s `constant(_:_:)`). A NOT
/// DETERMINISTIC routine — the default for a host-registered closure, which may
/// be stateful or observe the clock — is NEVER executed at compile time: it
/// could return one value while types are being computed and another when the
/// row is actually reached. The RUN path invokes any routine regardless;
/// determinism gates only compile-time folding.
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

  /// The number of REQUIRED leading arguments; arguments beyond it (up to
  /// `parameters.count`) are OPTIONAL, so a call's arity may be anywhere in
  /// `minimum ... parameters.count`. Defaults to `parameters.count` — all
  /// required, a fixed arity — so every fixed-arity routine is unchanged.
  /// `OVERLAY` sets it to 3 with an optional fourth `length` the routine
  /// DEFAULTS from its once-evaluated replacement, so the parser need not
  /// re-reference the replacement (which would double-evaluate a
  /// non-deterministic one).
  public let minimum: Int

  /// The declared result type, read to type a call statically.
  public let returns: ValueType

  /// Whether this routine is DETERMINISTIC (ISO SQL) — same arguments yield the
  /// same value with no side effect. Only a deterministic routine is folded at
  /// compile time (`Resolve`'s `constant(_:_:)`); a NOT DETERMINISTIC one is
  /// left for the run to invoke.
  public let deterministic: Bool

  /// The routine's implementation.
  private let body: Body

  public init(returns: ValueType = .integer, parameters: Array<ValueType>,
              minimum: Int? = nil, deterministic: Bool = false,
              _ compute: @escaping @Sendable (Array<Value>)
                  throws(SQLError) -> Value) {
    self.parameters = parameters
    self.minimum = minimum ?? parameters.count
    self.returns = returns
    self.deterministic = deterministic
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
  ///
  /// A defined routine is NOT DETERMINISTIC: the DDL (`CREATE FUNCTION`) has no
  /// `DETERMINISTIC` clause yet, so ISO's default characteristic applies and
  /// the body is never folded at compile time — the safe choice, since it may
  /// call a non-deterministic routine.
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
    self.minimum = parameters.count
    self.returns = returns
    self.deterministic = false
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
      // The body's lowered `term` cannot nest a subquery — a `CREATE FUNCTION`
      // body lowers against `Subquery.unsupported` (no catalog), which rejects
      // one at registration — so the subquery-free evaluate suffices.
      return try Record(arguments).evaluate(term, routines)
    }
  }
}

/// An empty `Catalog` vending no relation — the stand-in for the absent catalog
/// where the evaluator runs a subquery-FREE term.
///
/// A `CREATE FUNCTION` body lowers against `Subquery.unsupported`, so its term
/// can never nest a scalar subquery and its evaluation never needs a catalog to
/// materialise one. Passing this empty catalog keeps ONE evaluator: a term that
/// did reach a `.subquery` would run `cell(of:)` against a catalog resolving no
/// relation and fault, but a function body never does.
internal struct NoCatalog: Catalog {
  internal struct Table: SQLEngine.Table {
    internal struct Cursor: SQLEngine.Cursor {
      internal struct Row: SQLEngine.Row {
        internal subscript(_ column: Int) -> Value { .null }
      }

      internal var count: Int { 0 }
      internal func row(_ index: Int) -> Row? { nil }
    }

    internal var width: Int { 0 }
    internal var names: Array<String> { [] }
    internal func ordinal(of name: String) -> Int? { nil }
    internal func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
      nil
    }

    internal func cursor() -> Cursor { Cursor() }
  }

  internal func table(named name: String) -> Table? { nil }
  internal func relations() -> Array<String> { [] }
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

  /// The case-folded names that `registering(_:…)` refuses to bind — the
  /// PROTECTED routines a standard-library prelude marks so a caller extending
  /// it cannot shadow an ISO built-in and silently change what a query naming
  /// it computes. The set travels WITH the value: the empty routines and a
  /// dictionary literal carry none (the escape hatch a prelude is BUILT
  /// through), and `merging(_:)` unions both sides' sets, so protection is a
  /// property of the routines rather than a module-wide constant. The engine
  /// itself ships no built-in, so a `Routines` it builds is unprotected; the
  /// `SQLStandard` prelude marks its own names (see `protecting(_:)`).
  private let protected: Set<String>

  /// Empty routines — every call faults until a routine is registered.
  public init() {
    self.functions = [:]
    self.protected = []
  }

  /// Routines over a `name → routine` map; each name folds to lower case so a
  /// call resolves by the SQL identifier rule. Two names differing only by case
  /// merge (the later-sorting original spelling wins) instead of trapping. The
  /// map carries no protected names — it is the lower-level escape hatch a
  /// prelude is built through (see `protecting(_:)`).
  public init(_ functions: Dictionary<String, Routine>) {
    self.functions = functions.sorted { $0.key < $1.key }
      .reduce(into: Dictionary<String, Routine>()) {
        $0[$1.key.lowercased()] = $1.value
      }
    self.protected = []
  }

  /// A private designated initializer carrying an explicit protected-name set,
  /// so `protecting(_:)` and `merging(_:)` can preserve or union it while the
  /// public inits default it empty.
  private init(_ functions: Dictionary<String, Routine>,
               protected: Set<String>) {
    self.functions = functions
    self.protected = protected
  }

  /// These routines with `names` (case-folded) marked PROTECTED — the seam a
  /// standard-library prelude uses to declare its built-ins non-shadowable: a
  /// later `registering(_:…)` of a protected name faults SQLSTATE `42723`
  /// rather than shadow it. The engine ships no prelude, so it never calls
  /// this; `SQLStandard` marks the standard routines' own names.
  public func protecting(_ names: Set<String>) -> Routines {
    Routines(functions,
             protected: protected.union(names.map { $0.lowercased() }))
  }

  /// The case-folded names of the registered routines — the set a prelude
  /// passes to `protecting(_:)` to mark its own built-ins non-shadowable.
  public var names: Set<String> {
    Set(functions.keys)
  }

  /// The routine `name` names, folded to lower case like every other SQL
  /// identifier, or `nil` if no registered routine bears it. There is a single
  /// flat map with no privileged tier at LOOKUP: a prelude routine
  /// (`Routines.standard`) and a caller-registered one resolve through the same
  /// lookup, so a name resolves to whatever the map binds. (A future PATH /
  /// search-order mechanism — à la DB2 or PostgreSQL — would let a qualified
  /// call reach a specific one across schemas.) A caller does not REACH this
  /// map past a standard name, though: `registering(_:…)` refuses to bind one
  /// (see `protected`), so the shadowing a lower-level `init` still permits
  /// never arises through the public extension surface.
  public subscript(_ name: String) -> Routine? {
    functions[name.lowercased()]
  }

  /// Faults if `name` (case-folded) is a protected routine of THESE routines —
  /// the check both `registering` overloads apply before binding, so neither
  /// the closure nor the `CREATE FUNCTION` path shadows a name a prelude marked
  /// (see `protecting(_:)`). It carries SQLSTATE `42723` (duplicate function,
  /// the PostgreSQL subclass on the `42` class) via the `.state` passthrough —
  /// no semantic case models a reserved-name fault, and `.function`'s message
  /// ("no such function") would misdescribe the condition.
  private func reserved(_ name: String) throws(SQLError) {
    guard !protected.contains(name.lowercased()) else {
      throw .state("42723", "'\(name)' is a standard routine and "
                       + "cannot be redefined")
    }
  }

  /// A copy of these routines with a routine computing `compute`, accepting
  /// `parameters` (default none), and returning `returns` (default `.integer`)
  /// bound to `name` (folded to lower case), the binding shadowing any existing
  /// one — UNLESS `name` is a protected standard routine (`reserved(_:)`),
  /// which faults rather than shadow an ISO built-in. `deterministic` declares
  /// the routine's ISO SQL characteristic and defaults to `false` (NOT
  /// DETERMINISTIC) — the safe default for a host closure, which may be
  /// stateful or read the clock: it is not executed at compile time. Pass
  /// `true` for a pure routine to let a row-independent call fold.
  //
  // `SQLEngine.Value` is spelled in full here and in `bitand`: `Routines`
  // conforms to `ExpressibleByDictionaryLiteral`, whose associated `Value` is
  // the literal's element `Routine`, so an unqualified `Value` inside
  // `Routines` names that element, not the engine cell the routine computes.
  public func registering(_ name: String, returns: ValueType = .integer,
                          parameters: Array<ValueType> = [],
                          deterministic: Bool = false,
                          _ compute:
                              @escaping @Sendable (Array<SQLEngine.Value>)
                                  throws(SQLError) -> SQLEngine.Value)
      throws(SQLError) -> Routines {
    try reserved(name)
    var functions = self.functions
    functions[name.lowercased()] =
        Routine(returns: returns, parameters: parameters,
                deterministic: deterministic, compute)
    return Routines(functions, protected: protected)
  }

  /// A copy of these routines with the DEFINED `function` bound to `name`
  /// (folded to lower case), the binding shadowing any existing one — UNLESS
  /// `name` is a protected standard routine (`reserved(_:)`), which faults
  /// rather than shadow an ISO built-in — the registration a consumer performs
  /// for a parsed `CREATE FUNCTION`, mirroring a catalog registering a `CREATE
  /// VIEW`'s `View`.
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
  /// `ambient` routines OVERLAID with these routines — `ambient` merged under
  /// the map before this registration (the prelude is the base, a caller
  /// registration shadows a like-named prelude routine) — and resolves its
  /// nested calls through that captured environment at run time, the ISO
  /// subject-routine rule (a body's routine references are fixed when it is
  /// defined). `ambient` is the environment a prelude layer supplies so a body
  /// may call a built-in: `SQLStandard` passes `Routines.standard`, so
  /// `lowbit(n) AS BITAND(n, 1)` resolves `BITAND` here exactly as an ordinary
  /// `SELECT` would, rather than faulting at registration for a routine the
  /// query path can see. The pure engine supplies no ambient of its own —
  /// `import SQLStandard` re-defaults it (see the two-argument overload there).
  /// A body naming its OWN registration `name` is well-defined, not recursion:
  /// `f() AS f() + 1` REPLACING a prior `f` captures the OLD `f`, so it
  /// computes `f_old() + 1` and terminates. With NO prior `f` and no ambient
  /// `f`, the captured map lacks `f`, so the body's call is unresolved and the
  /// returns validation above faults `SQLError.function` — the
  /// unregistered-callee case, not a self-reference one. Query-level resolution
  /// is UNCHANGED: a top-level `SELECT f()` still resolves `f` to the LATEST
  /// binding (a later registration shadows an earlier one); capture governs
  /// only a body's INTERNAL calls, not which `f` a query reaches.
  public func registering(_ name: String, _ function: Function,
                          capturing ambient: Routines)
      throws(SQLError) -> Routines {
    try reserved(name)
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
                    body: function.body, ambient.merging(self))
    return Routines(functions, protected: protected)
  }

  /// These routines overlaid with `other`'s — a caller composing two routine
  /// sources (e.g. a target-language spec's UDFs and a data source's domain
  /// UDFs). A name `other` also binds shadows this one's; names are already
  /// case-folded on both sides. Both sides' protected names are unioned, so
  /// merging a prelude in keeps its built-ins non-shadowable (see
  /// `protecting(_:)`).
  public func merging(_ other: Routines) -> Routines {
    Routines(functions.merging(other.functions) { _, last in last },
             protected: protected.union(other.protected))
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
