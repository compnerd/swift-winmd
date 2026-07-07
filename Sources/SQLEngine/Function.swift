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
      return try Record(arguments).evaluate(term, routines)
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

  /// The names of the standard-library routines, case-folded — the built-ins
  /// `Routines.standard` seeds. These are PROTECTED: `registering(_:…)` rejects
  /// a binding of any of them, so a caller extending the prelude cannot shadow
  /// an ISO built-in and silently change what a query naming it computes.
  /// Constructing a `Routines` DIRECTLY through `init(_:)` or the dictionary
  /// literal is a lower-level escape hatch that still admits a standard name —
  /// it is how `standard` itself is built — but the public composition API
  /// (`registering`) does not.
  private static let protected = Set(standard.functions.keys)

  /// Faults if `name` (case-folded) is a protected standard routine — the check
  /// both `registering` overloads apply before binding, so neither the closure
  /// nor the `CREATE FUNCTION` path shadows a built-in. It carries SQLSTATE
  /// `42723` (duplicate function, the PostgreSQL subclass on the `42` class)
  /// via the `.state` passthrough — no semantic case models a reserved-name
  /// fault, and `.function`'s message ("no such function") would misdescribe
  /// the condition.
  private static func reserved(_ name: String) throws(SQLError) {
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
    try Routines.reserved(name)
    var functions = self.functions
    functions[name.lowercased()] =
        Routine(returns: returns, parameters: parameters,
                deterministic: deterministic, compute)
    return Routines(functions)
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
    try Routines.reserved(name)
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
  /// the flat registry at the public entry points (`Routines.standard` merged
  /// under a caller's routines) so a query reaches them without a caller
  /// registering a closure. They are PROTECTED: a caller cannot shadow one
  /// through `registering(_:…)` (see `protected`/`reserved(_:)`), so a query
  /// naming a built-in always reaches the shipped one. Every member is a pure,
  /// side-effect-free mapping and so DETERMINISTIC — a row-independent call
  /// folds at compile time — and returns NULL on any NULL argument (SQL null
  /// propagation), faulting `SQLError.argument` on the wrong argument count or
  /// a value it cannot map, mirroring its declared `[parameters]`/`returns`
  /// contract the static type-check validates a call against.
  ///
  /// The set covers the ISO scalar built-ins the grammar can already CALL
  /// (`f(…)`), in two families:
  ///
  /// - STRING: `UPPER`/`LOWER` (case fold), `CHAR_LENGTH` (with its ISO synonym
  ///   `CHARACTER_LENGTH`, the same routine under both names), `SUBSTRING` (the
  ///   two-argument `SUBSTRING(text, start)` form, ISO 1-based indexing),
  ///   `TRIM` (the one-argument `TRIM(text)` form, stripping leading and
  ///   trailing spaces), `POSITION` (the ISO `POSITION(substring IN string)`
  ///   form the parser desugars to `position(substring, string)`, 1-based, 0
  ///   when absent), and `OVERLAY` (the ISO `OVERLAY(string PLACING replacement
  ///   FROM start [FOR length])` form the parser desugars to `overlay(string,
  ///   replacement, start[, length])` — an optional-tail routine (`minimum` 3)
  ///   that defaults an omitted `length` to the once-evaluated replacement's
  ///   character count itself, so the parser need not re-reference the
  ///   replacement).
  /// - NUMERIC: `ABS`, `ROUND` (the one-argument form, to the nearest integer
  ///   value), `CEILING` (with its synonym `CEIL`), `FLOOR`, and `MOD` (the
  ///   two-integer remainder — `BITAND`'s numeric sibling, an operation the
  ///   grammar's `%` otherwise lacks a call spelling for). `BITAND` — the
  ///   portable, standards-compliant spelling (Oracle's) of a bitwise AND, an
  ///   operation ISO SQL and this grammar otherwise lack — is kept.
  ///
  /// FOLLOW-UPS (each needs grammar or overloading this batch does not add, so
  /// each ships in its simplest callable form now):
  /// - `SUBSTRING(text FROM start FOR length)` — the full ISO clause with a
  ///   `FROM`/`FOR` keyword syntax and an optional length — and the plain
  ///   three-argument `SUBSTRING(text, start, length)` could now adopt the
  ///   optional-tail arity `OVERLAY` introduced (`minimum` 2, an optional third
  ///   `length`); only the two-argument prefix form ships in this batch.
  /// - `TRIM([{LEADING | TRAILING | BOTH}] [char] FROM text)` — the full ISO
  ///   clause with a trim specification and a trim character — needs grammar;
  ///   only the leading-and-trailing-space `TRIM(text)` form ships.
  /// - `ROUND(n, places)` — rounding to a decimal place — could now use the
  ///   optional-tail arity (`minimum` 1); only the nearest-integer `ROUND(n)`
  ///   form ships in this batch.
  /// - The numeric routines are declared over `double` (`returns` a `double`,
  ///   save `MOD`'s integer remainder), so an INTEGER argument does not satisfy
  ///   the static contract (the type-check is exact-equality — an integer is
  ///   not a double); an integer-domain overload (`ABS(integer) → integer`, …)
  ///   needs routine overloading, which the single-signature contract lacks.
  public static let standard: Routines = [
    "bitand": Routine(returns: .integer, parameters: [.integer, .integer],
                      deterministic: true, bitand),
    "upper": Routine(returns: .text, parameters: [.text],
                     deterministic: true, upper),
    "lower": Routine(returns: .text, parameters: [.text],
                     deterministic: true, lower),
    "char_length": Routine(returns: .integer, parameters: [.text],
                           deterministic: true, length),
    "character_length": Routine(returns: .integer, parameters: [.text],
                                deterministic: true, length),
    "substring": Routine(returns: .text, parameters: [.text, .integer],
                         deterministic: true, substring),
    "trim": Routine(returns: .text, parameters: [.text],
                    deterministic: true, trim),
    "abs": Routine(returns: .double, parameters: [.double],
                   deterministic: true, abs),
    "round": Routine(returns: .double, parameters: [.double],
                     deterministic: true, round),
    "ceiling": Routine(returns: .double, parameters: [.double],
                       deterministic: true, ceiling),
    "ceil": Routine(returns: .double, parameters: [.double],
                    deterministic: true, ceiling),
    "floor": Routine(returns: .double, parameters: [.double],
                     deterministic: true, floor),
    "mod": Routine(returns: .integer, parameters: [.integer, .integer],
                   deterministic: true, mod),
    "position": Routine(returns: .integer, parameters: [.text, .text],
                        deterministic: true, position),
    "overlay": Routine(returns: .text,
                       parameters: [.text, .text, .integer, .integer],
                       minimum: 3, deterministic: true, overlay),
  ]

  /// The single `.null` short-circuit ISO null propagation gives every built-in
  /// — a NULL argument yields NULL — factored out so each routine reads as its
  /// mapping alone. Returns `true` when any argument is NULL, so the caller
  /// returns `.null` before matching a concrete kind.
  private static func propagates(_ arguments: Array<SQLEngine.Value>) -> Bool {
    arguments.contains(.null)
  }

  /// `BITAND(x, y)` — the bitwise AND of two integers. A NULL argument yields
  /// NULL (SQL null propagation); the wrong argument count or a non-integer
  /// argument is `SQLError.argument` (a function-argument fault — not
  /// `SQLError.arity`, which is the UNION column-count mismatch). Its declared
  /// `[.integer, .integer]` contract is what the static type-check validates a
  /// call against, mirroring these run-time faults.
  private static func bitand(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("BITAND takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .integer(x) = arguments[0],
        case let .integer(y) = arguments[1] else {
      throw .argument("BITAND requires integer arguments")
    }
    return .integer(x & y)
  }

  /// `UPPER(text)` — the string upper-cased. A NULL argument yields NULL; the
  /// wrong count or a non-text argument is `SQLError.argument`.
  private static func upper(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("UPPER takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("UPPER requires a text argument")
    }
    return .text(string.uppercased())
  }

  /// `LOWER(text)` — the string lower-cased. A NULL argument yields NULL; the
  /// wrong count or a non-text argument is `SQLError.argument`.
  private static func lower(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("LOWER takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("LOWER requires a text argument")
    }
    return .text(string.lowercased())
  }

  /// `CHAR_LENGTH(text)` / `CHARACTER_LENGTH(text)` — the number of characters
  /// in the string (its Unicode character count, not its UTF-8 byte length). A
  /// NULL argument yields NULL; the wrong count or a non-text argument is
  /// `SQLError.argument`.
  private static func length(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("CHAR_LENGTH takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("CHAR_LENGTH requires a text argument")
    }
    return .integer(string.count)
  }

  /// `SUBSTRING(text, start)` — the substring of `text` from the 1-based
  /// `start` character to the end, the ISO indexing where the first character
  /// is position 1. A `start` at or before 1 begins at the first character; a
  /// `start` past the end yields the empty string. A NULL argument yields NULL;
  /// the wrong count, a non-text first argument, or a non-integer second is
  /// `SQLError.argument`.
  private static func substring(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("SUBSTRING takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0],
        case let .integer(start) = arguments[1] else {
      throw .argument("SUBSTRING requires a text and an integer argument")
    }
    // ISO positions are 1-based; a start at or before 1 clamps to the first
    // character, and one past the end clamps to the end (the empty tail). The
    // `start - 1` conversion overflows for `Int.min`, so a start at or before
    // 1 takes the whole string directly rather than subtracting.
    let drop = start > 1 ? start - 1 : 0
    return .text(String(string.dropFirst(drop)))
  }

  /// `TRIM(text)` — the string with leading and trailing SPACE characters
  /// removed (the one-argument ISO form, whose implicit trim character is a
  /// space and whose implicit specification is BOTH). A NULL argument yields
  /// NULL; the wrong count or a non-text argument is `SQLError.argument`.
  private static func trim(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("TRIM takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("TRIM requires a text argument")
    }
    return .text(String(string.drop(while: { $0 == " " })
                            .reversed().drop(while: { $0 == " " })
                            .reversed()))
  }

  /// `ABS(n)` — the absolute value of a real number. A NULL argument yields
  /// NULL; the wrong count or a non-double argument is `SQLError.argument`.
  private static func abs(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("ABS takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("ABS requires a double argument")
    }
    return .double(Swift.abs(value))
  }

  /// `ROUND(n)` — the real number rounded to the nearest integer value (ties
  /// away from zero, the ISO default), carried as a double. A NULL argument
  /// yields NULL; the wrong count or a non-double argument is
  /// `SQLError.argument`.
  private static func round(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("ROUND takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("ROUND requires a double argument")
    }
    return .double(value.rounded())
  }

  /// `CEILING(n)` / `CEIL(n)` — the least integer value not less than `n`,
  /// carried as a double. A NULL argument yields NULL; the wrong count or a
  /// non-double argument is `SQLError.argument`.
  private static func ceiling(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("CEILING takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("CEILING requires a double argument")
    }
    return .double(value.rounded(.up))
  }

  /// `FLOOR(n)` — the greatest integer value not greater than `n`, carried as a
  /// double. A NULL argument yields NULL; the wrong count or a non-double
  /// argument is `SQLError.argument`.
  private static func floor(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("FLOOR takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("FLOOR requires a double argument")
    }
    return .double(value.rounded(.down))
  }

  /// `MOD(a, b)` — the remainder of `a` divided by `b`, both integers (the ISO
  /// `MOD` function, distinct from the grammar's `%` operator). A zero divisor
  /// is `SQLError.divide`, as integer arithmetic's `%` by zero is. A NULL
  /// argument yields NULL; the wrong count or a non-integer argument is
  /// `SQLError.argument`.
  private static func mod(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("MOD takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .integer(a) = arguments[0],
        case let .integer(b) = arguments[1] else {
      throw .argument("MOD requires integer arguments")
    }
    guard b != 0 else { throw .divide }
    // `a % -1` is mathematically 0, but `Int.min % -1` overflows the implied
    // division and traps, so a divisor of -1 short-circuits to that 0.
    guard b != -1 else { return .integer(0) }
    return .integer(a % b)
  }

  /// `POSITION(substring, string)` — the parser's desugaring of the ISO
  /// `POSITION(substring IN string)` — the 1-based character position of the
  /// first occurrence of `substring` in `string`, 0 when it does not occur. An
  /// EMPTY substring occurs at position 1 (ISO): the empty string is a prefix
  /// of every string, including another empty string. Matching is
  /// character-wise and case-SENSITIVE (no case fold). A NULL argument yields
  /// NULL; the wrong count or a non-text argument is `SQLError.argument`.
  private static func position(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("POSITION takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(substring) = arguments[0],
        case let .text(string) = arguments[1] else {
      throw .argument("POSITION requires text arguments")
    }
    // The empty substring is a prefix of every string, so it occurs at 1.
    guard !substring.isEmpty else { return .integer(1) }
    // Character-wise search over the Unicode scalars `CHAR_LENGTH` counts, so
    // the reported position is a 1-based character index, not a byte offset.
    let haystack = Array(string), needle = Array(substring)
    guard haystack.count >= needle.count else { return .integer(0) }
    for start in 0...(haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
      return .integer(start + 1)
    }
    return .integer(0)
  }

  /// `OVERLAY(string, replacement, start, length)` — the parser's desugaring of
  /// the ISO `OVERLAY(string PLACING replacement FROM start [FOR length])` —
  /// the `string` with `length` characters from the 1-based `start` replaced by
  /// `replacement`. The optional `FOR length` defaults, in the parser, to the
  /// replacement's character count, so the four-argument form is the only one
  /// this routine sees. A NULL argument yields NULL; the wrong count, a
  /// non-text `string`/`replacement`, or a non-integer `start`/`length` is
  /// `SQLError.argument`.
  ///
  /// The 1-based `start` and the `length` are CLAMPED to the string rather than
  /// trusted, so no arithmetic traps and no slice runs out of bounds: a `start`
  /// at or before 1 begins at the first character (the `start - 1` conversion
  /// would overflow for `Int.min`, so it is not subtracted below 1), a `start`
  /// past the end appends, a negative `length` removes nothing, and a `length`
  /// past the end removes only to the end. This is `SUBSTRING`'s clamp
  /// discipline applied to both the prefix kept and the suffix resumed.
  private static func overlay(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard (3 ... 4).contains(arguments.count) else {
      throw .argument("OVERLAY takes three or four arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0],
        case let .text(replacement) = arguments[1],
        case let .integer(start) = arguments[2] else {
      throw .argument("OVERLAY requires text, text, and integer arguments")
    }
    // The number of characters to remove: the explicit `FOR length` fourth
    // argument, or — when omitted — the character count of the replacement.
    // Defaulting HERE, from the single evaluated replacement value, is what
    // lets the parser pass only three arguments for the omitted-`FOR` form:
    // the replacement is evaluated ONCE, so a NOT-DETERMINISTIC one
    // (`stepper_text()`) both inserts and measures the SAME value, rather than
    // the parser re-referencing it as `char_length(replacement)` and
    // evaluating it a second time.
    let length: Int
    if arguments.count == 4 {
      guard case let .integer(explicit) = arguments[3] else {
        throw .argument("OVERLAY requires an integer length")
      }
      length = explicit
    } else {
      length = replacement.count
    }
    let characters = Array(string)
    // The prefix kept is `start - 1` characters, clamped into `[0, count]`; the
    // `start - 1` is not computed for a start at or before 1, which would
    // overflow at `Int.min`, and is capped at the string's length so a start
    // past the end keeps the whole string and appends.
    let head = start > 1 ? Swift.min(start - 1, characters.count) : 0
    // The suffix resumes `length` characters after `head`, clamped the same
    // way: a negative or zero length removes nothing (resumes at `head`), and a
    // length past the end resumes at the end. The overshoot is tested against
    // the REMAINING capacity (`count - head`) rather than forming `head +
    // length`, whose sum would overflow for an `Int.max` length.
    let tail = if length <= 0 {
      head
    } else if length < characters.count - head {
      head + length
    } else {
      characters.count
    }
    return .text(String(characters[..<head]) + replacement
                     + String(characters[tail...]))
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
