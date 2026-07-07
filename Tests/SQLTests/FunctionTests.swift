// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

@Suite struct RoutineTests {
  @Test func `a routine's return type defaults to integer`() {
    #expect(Routine(parameters: []) { _ in .integer(0) }.returns == .integer)
  }

  @Test func `a routine carries its declared return type`() {
    #expect(Routine(returns: .text, parameters: []) { _ in .text("x") }
                .returns == .text)
  }

  @Test func `a routine carries its declared parameter contract`() {
    let routine = Routine(parameters: [.integer, .text]) { _ in .integer(0) }
    #expect(routine.parameters == [.integer, .text])
  }

  @Test func `a routine is called to compute a value`() throws {
    let double = Routine(parameters: [.integer]) { arguments in
      guard case let .integer(x) = arguments[0] else { return .null }
      return .integer(x * 2)
    }
    #expect(try double([.integer(21)]) == .integer(42))
  }

  @Test func `a Routine literal registers its declared signature`() {
    // A client's documented shape: the literal value is a `Routine`, so each
    // registration declares its full signature — its parameters and return
    // type.
    let routines: Routines =
        ["upper": Routine(returns: .text, parameters: [.text]) {
          _ in .text("X")
        }]
    #expect(routines["upper"]?.returns == .text)
    #expect(routines["upper"]?.parameters == [.text])
  }

  @Test func `registering declares a signature, the return defaulting to integer`() throws {
    let routines = try Routines()
        .registering("t", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
        .registering("i", parameters: [.integer]) { _ in .integer(0) }
    #expect(routines["t"]?.returns == .text)
    #expect(routines["i"]?.returns == .integer)
  }

  @Test func `the name subscript resolves case-insensitively`() {
    let routines: Routines =
        ["Tag": Routine(returns: .text, parameters: []) { _ in .text("x") }]
    #expect(routines["TAG"] != nil)
    #expect(routines["nope"] == nil)
  }

  @Test func `the standard prelude declares BITAND over two integers`() {
    #expect(Routines.standard["bitand"]?.returns == .integer)
    #expect(Routines.standard["bitand"]?.parameters == [.integer, .integer])
  }
}

/// A small catalog the standard-library tests project the built-ins over. Its
/// columns give each built-in an argument of the RIGHT type (`Text`, `Num`,
/// `Real`) and, in a second row, a NULL of each, so a call over a column and a
/// call over a NULL both run. `Pad` is a text column with leading and trailing
/// spaces for `TRIM`. A third row carries `Int.min` in `Num` so the integer
/// routines are exercised at the edge where a naive `start - 1` or `a % -1`
/// would overflow and trap.
private func library() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Id": .integer, "Text": .text, "Pad": .text,
                   "Num": .integer, "Real": .double]) {
      Row(1, "aBc", "  hi  ", -7, -2.5)
      Row(2, nil, nil, nil, nil)
      Row(3, "hello", "", Int.min, 0.0)
    }
  }
}

@Suite struct StandardLibraryTests {
  // MARK: - Declared signatures

  @Test func `each standard routine declares its signature`() {
    let standard = Routines.standard
    #expect(standard["upper"]?.returns == .text)
    #expect(standard["upper"]?.parameters == [.text])
    #expect(standard["lower"]?.returns == .text)
    #expect(standard["char_length"]?.returns == .integer)
    #expect(standard["char_length"]?.parameters == [.text])
    #expect(standard["character_length"]?.returns == .integer)
    #expect(standard["substring"]?.parameters == [.text, .integer])
    #expect(standard["substring"]?.returns == .text)
    #expect(standard["trim"]?.returns == .text)
    #expect(standard["abs"]?.parameters == [.double])
    #expect(standard["abs"]?.returns == .double)
    #expect(standard["round"]?.returns == .double)
    #expect(standard["ceiling"]?.returns == .double)
    #expect(standard["ceil"]?.returns == .double)
    #expect(standard["floor"]?.returns == .double)
    #expect(standard["mod"]?.parameters == [.integer, .integer])
    #expect(standard["mod"]?.returns == .integer)
  }

  @Test func `every standard routine is deterministic`() {
    for name in ["bitand", "upper", "lower", "char_length",
                 "character_length", "substring", "trim", "abs", "round",
                 "ceiling", "ceil", "floor", "mod"] {
      #expect(Routines.standard[name]?.deterministic == true)
    }
  }

  @Test func `columns(of:) reports a built-in call by its declared type`() throws {
    // The schema walk types a call by its routine's `returns`, so a projected
    // built-in reports the declared header — text for UPPER, integer for
    // CHAR_LENGTH, double for ROUND — when the standard prelude is in scope.
    let query = try Statement(parsing:
        "SELECT UPPER(Text), CHAR_LENGTH(Text), ROUND(Real) FROM L")
    let typed = try library().columns(of: query, routines: .standard)
    #expect(typed.map(\.type) == [.text, .integer, .double])
  }

  // MARK: - String routines

  @Test func `UPPER and LOWER fold a text column`() throws {
    try library().expect("SELECT UPPER(Text), LOWER(Text) FROM L WHERE Id = 1",
                         yields: [["ABC", "abc"]], routines: .standard)
  }

  @Test func `UPPER folds a text literal`() throws {
    try library().expect("SELECT UPPER('aBc') FROM L WHERE Id = 1",
                         yields: [["ABC"]], routines: .standard)
  }

  @Test func `CHAR_LENGTH and its synonym count characters`() throws {
    try library().expect(
        "SELECT CHAR_LENGTH(Text), CHARACTER_LENGTH(Text) FROM L WHERE Id = 1",
        yields: [[3, 3]], routines: .standard)
  }

  @Test func `SUBSTRING takes an ISO 1-based start`() throws {
    // Position 2 of 'aBc' is 'Bc'; a start at or before 1 is the whole string.
    try library().expect("SELECT SUBSTRING(Text, 2) FROM L WHERE Id = 1",
                         yields: [["Bc"]], routines: .standard)
    try library().expect("SELECT SUBSTRING(Text, 1) FROM L WHERE Id = 1",
                         yields: [["aBc"]], routines: .standard)
  }

  @Test func `SUBSTRING clamps a start at or before 1 to the whole string`()
      throws {
    // A start of 0, a negative start, and the extreme `Int.min` all clamp to
    // the first character; the `Int.min` case would trap on a naive
    // `start - 1`, so it exercises the guarded conversion over an integer
    // column.
    try library().expect("SELECT SUBSTRING(Text, 0) FROM L WHERE Id = 3",
                         yields: [["hello"]], routines: .standard)
    try library().expect("SELECT SUBSTRING(Text, Num) FROM L WHERE Id = 1",
                         yields: [["aBc"]], routines: .standard)
    try library().expect("SELECT SUBSTRING(Text, Num) FROM L WHERE Id = 3",
                         yields: [["hello"]], routines: .standard)
    try library().expect("SELECT SUBSTRING(Text, 2) FROM L WHERE Id = 3",
                         yields: [["ello"]], routines: .standard)
  }

  @Test func `TRIM strips leading and trailing spaces`() throws {
    try library().expect("SELECT TRIM(Pad) FROM L WHERE Id = 1",
                         yields: [["hi"]], routines: .standard)
  }

  // MARK: - Numeric routines

  @Test func `ABS takes the magnitude of a real number`() throws {
    try library().expect("SELECT ABS(Real) FROM L WHERE Id = 1",
                         yields: [[2.5]], routines: .standard)
  }

  @Test func `ROUND CEILING CEIL and FLOOR shape a real number`() throws {
    try library().expect(
        "SELECT ROUND(2.5), CEILING(2.1), CEIL(2.1), FLOOR(2.9) FROM L "
            + "WHERE Id = 1",
        yields: [[3.0, 3.0, 3.0, 2.0]], routines: .standard)
  }

  @Test func `MOD takes the integer remainder`() throws {
    try library().expect("SELECT MOD(7, 3), MOD(Num, 3) FROM L WHERE Id = 1",
                         yields: [[1, -1]], routines: .standard)
  }

  @Test func `MOD by zero faults like integer division`() throws {
    try library().expect("SELECT MOD(7, 0) FROM L WHERE Id = 1",
                         fails: .divide, routines: .standard)
  }

  @Test func `MOD of Int.min by -1 and by 1 is zero without trapping`()
      throws {
    // `Int.min % -1` overflows the implied division and traps, so a divisor
    // of -1 short-circuits to the mathematical remainder, 0; `Int.min % 1` is
    // 0 too. The divisor is spelt `0 - 1` since the grammar has no negative
    // literal.
    try library().expect("SELECT MOD(Num, 0 - 1) FROM L WHERE Id = 3",
                         yields: [[0]], routines: .standard)
    try library().expect("SELECT MOD(Num, 1) FROM L WHERE Id = 3",
                         yields: [[0]], routines: .standard)
  }

  // MARK: - NULL propagation

  @Test func `a built-in returns NULL on a NULL argument`() throws {
    // Every built-in propagates NULL, the way BITAND does — the Id = 2 row
    // holds a NULL in each column.
    try library().expect(
        "SELECT UPPER(Text), CHAR_LENGTH(Text), SUBSTRING(Text, 1), "
            + "TRIM(Pad), ABS(Real), ROUND(Real), FLOOR(Real), MOD(Num, 3) "
            + "FROM L WHERE Id = 2",
        yields: [[nil, nil, nil, nil, nil, nil, nil, nil]],
        routines: .standard)
  }

  // MARK: - Bad arity and kind

  @Test func `a built-in faults on the wrong argument count`() throws {
    // The run path invokes the routine without a prior static type-check, so
    // each built-in's own arity check reports the count fault.
    try library().expect("SELECT UPPER(Text, Text) FROM L WHERE Id = 1",
                         fails: .argument("UPPER takes one argument"),
                         routines: .standard)
    try library().expect("SELECT MOD(1) FROM L WHERE Id = 1",
                         fails: .argument("MOD takes two arguments"),
                         routines: .standard)
  }

  @Test func `a built-in faults on a wrong-typed argument`() throws {
    // Likewise the run invokes the routine, whose own kind check faults a
    // numeric column passed to UPPER's text argument and a text column passed
    // to MOD's integer arguments.
    try library().expect("SELECT UPPER(Num) FROM L WHERE Id = 1",
                         fails: .argument("UPPER requires a text argument"),
                         routines: .standard)
    try library().expect("SELECT MOD(Text, 1) FROM L WHERE Id = 1",
                         fails: .argument("MOD requires integer arguments"),
                         routines: .standard)
  }

  // MARK: - Protection (non-shadowable)

  @Test func `registering over a standard routine is rejected`() {
    // A standard built-in is protected: `registering` refuses to bind its name
    // (SQLSTATE 42723) rather than shadow it.
    #expect(throws: SQLError.state("42723",
        "'upper' is a standard routine and cannot be redefined")) {
      try Routines().registering("upper", returns: .text,
                                 parameters: [.text]) { _ in .text("x") }
    }
  }

  @Test func `registering a defined function over a standard name is rejected`() {
    // The `CREATE FUNCTION` path is protected too: a defined routine cannot
    // take a built-in's name.
    let function = Function(parameters: [], returns: .integer,
                            body: .literal(.integer(0)))
    #expect(throws: SQLError.state("42723",
        "'floor' is a standard routine and cannot be redefined")) {
      try Routines().registering("floor", function)
    }
  }

  @Test func `protection resolves the name case-insensitively`() {
    // The guard case-folds the name like every identifier, so a differently-
    // cased spelling of a built-in is rejected too.
    #expect(throws: SQLError.state("42723",
        "'BitAnd' is a standard routine and cannot be redefined")) {
      try Routines().registering("BitAnd", parameters: [.integer, .integer]) {
        _ in .integer(0)
      }
    }
  }

  @Test func `registering a non-standard name still succeeds`() throws {
    // Protection covers only the standard set — a fresh name binds as before.
    let routines = try Routines().registering("mine", parameters: [.integer]) {
      _ in .integer(1)
    }
    #expect(routines["mine"] != nil)
  }
}

/// A one-row catalog the defined-routine contract tests run a call against. Its
/// `Name` column is TEXT and its `V` column holds a NULL, so a call over the
/// wrong-typed column and a call over a NULL argument both exercise the run
/// path.
private func numbers() throws -> FixtureCatalog {
  try Catalog {
    Relation("N", ["Id": .integer, "V": .integer, "Name": .text]) {
      Row(1, 7, "a")
      Row(2, nil, "b")
    }
  }
}

/// The `twice(n INTEGER) RETURNS INTEGER AS n + n` function, constructed
/// directly (bypassing the parser) so a contract is exercised at the model.
private func twice() -> Function {
  Function(parameters: [Function.Parameter(name: "n", type: .integer)],
           returns: .integer, body: .binary(.add, .column("n"), .column("n")))
}

/// The `id(n INTEGER) RETURNS INTEGER AS n` function — the identity over its
/// INTEGER parameter, so a wrong-typed argument reaches the body untyped unless
/// the run-path dispatch rejects it.
private func id() -> Function {
  Function(parameters: [Function.Parameter(name: "n", type: .integer)],
           returns: .integer, body: .column("n"))
}

@Suite struct RoutineContractTests {
  @Test func `a defined call with too few arguments faults at the run path`() throws {
    // A defined routine reaches the run path without a prior type-check, so its
    // arity is enforced in the call itself: `twice()` reads slot 0 of an empty
    // record, which would trap; the guard turns it into `SQLError.argument`.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice() FROM N WHERE Id = 1",
                         fails: .argument("takes 1 arguments"),
                         routines: routines)
  }

  @Test func `a defined call with too many arguments faults at the run path`() throws {
    // Extra arguments are not silently ignored: the arity guard rejects a call
    // wider than the declared parameters, the same `SQLError.argument` a native
    // routine's own count check raises.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V, V) FROM N WHERE Id = 1",
                         fails: .argument("takes 1 arguments"),
                         routines: routines)
  }

  @Test func `registering a body of the wrong type faults against the RETURNS`() {
    // `f(n INTEGER) RETURNS TEXT AS n + 1` derives an integer body against a
    // declared TEXT result — a contract violation caught at registration, the
    // moment the function binds, with the same `SQLError.argument` case the
    // argument contract reports.
    let function =
        Function(parameters: [Function.Parameter(name: "n", type: .integer)],
                 returns: .text,
                 body: .binary(.add, .column("n"), .literal(.integer(1))))
    #expect(throws: SQLError.argument(
        "the body yields integer, not the declared character varying")) {
      _ = try Routines().registering("f", function)
    }
  }

  @Test func `registering a body matching the RETURNS succeeds and runs`() throws {
    // A body whose derived type equals the declared result registers cleanly
    // and computes over its argument.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V) FROM N WHERE Id = 1",
                         yields: [[14]], routines: routines)
  }

  @Test func `a NULL result is allowed against any declared return type`() throws {
    // NULL is not a type — it propagates through any declared result — so a
    // body that yields NULL on a row (a NULL argument through its arithmetic)
    // does not violate the INTEGER contract the derivation checked.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V) FROM N WHERE Id = 2",
                         yields: [[nil]], routines: routines)
  }

  @Test func `a duplicate parameter on the public path faults with the later name`() {
    // The parser rejects a duplicate parameter, but a directly-constructed
    // `Function` bypasses it; the registration path applies the same
    // case-insensitive check so the second (unreachable) slot never registers.
    let function = Function(parameters: [
      Function.Parameter(name: "n", type: .integer),
      Function.Parameter(name: "n", type: .text),
    ], returns: .integer, body: .column("n"))
    #expect(throws: SQLError.duplicate("n")) {
      _ = try Routines().registering("dup", function)
    }
  }

  @Test func `registering a body calling an unregistered routine faults`() {
    // A defined body early-binds its calls against the routines captured at
    // definition. `f() RETURNS INTEGER AS g()` with `g` unknown captures a map
    // without `g`, so the returns validation cannot resolve the call: rather
    // than typing it by the `.integer` default and admitting a contract nothing
    // backs, the faulting check rejects the unresolved call outright.
    let function = Function(parameters: [], returns: .integer,
                            body: .call(name: "g", arguments: []))
    #expect(throws: SQLError.function("g")) {
      _ = try Routines().registering("f", function)
    }
  }

  @Test func `a body calling an already-registered routine adopts its return type`() throws {
    // With `g` registered first, `f() RETURNS TEXT AS g()` validates against
    // g's declared TEXT result and registers; the call resolves at run time.
    let g = Function(parameters: [], returns: .text,
                     body: .literal(.string("x")))
    let f = Function(parameters: [], returns: .text,
                     body: .call(name: "g", arguments: []))
    let routines = try Routines().registering("g", g).registering("f", f)
    try numbers().expect("SELECT f() FROM N WHERE Id = 1",
                         yields: [["x"]], routines: routines)
  }

  @Test func `a defined call with a wrong-typed argument faults at the run path`() throws {
    // Reached through the RUN path (no prior `columns(validate:)`), the defined
    // dispatch validates each argument's type, not only the arity: `id(Name)`
    // over a TEXT column would otherwise return a `.text` value against the
    // routine's INTEGER contract; the dispatch faults it, the same
    // `SQLError.argument` a native routine reports a wrong-typed argument with.
    let routines = try Routines().registering("id", id())
    try numbers().expect("SELECT id(Name) FROM N WHERE Id = 1",
                         fails: .argument("requires integer arguments"),
                         routines: routines)
  }

  @Test func `a defined call with a NULL argument is allowed and yields NULL`() throws {
    // NULL is not a type — it propagates through the body — so a NULL argument
    // bound to any declared parameter is admitted (exactly as `BITAND` returns
    // NULL on a NULL argument), and the identity body yields NULL.
    let routines = try Routines().registering("id", id())
    try numbers().expect("SELECT id(V) FROM N WHERE Id = 2",
                         yields: [[nil]], routines: routines)
  }

  @Test func `a defined call with a correct-typed argument returns the value`() throws {
    // A correct-typed argument passes the run-path type check and the identity
    // body returns it — the guard rejects only a definitively-wrong type.
    let routines = try Routines().registering("id", id())
    try numbers().expect("SELECT id(V) FROM N WHERE Id = 1",
                         yields: [[7]], routines: routines)
  }

  @Test func `a body naming its own unregistered name faults as unresolved`() {
    // `f() RETURNS INTEGER AS f() + 1` with NO prior `f` captures a map without
    // `f`, so the body's own call is unresolved: the returns validation faults
    // `SQLError.function`, the unregistered-callee case — not a self-reference
    // one. Early binding admits no recursion here; there is nothing to bind to.
    let call = Expression.call(name: "f", arguments: [])
    let function = Function(parameters: [], returns: .integer,
                            body: .binary(.add, call, .literal(.integer(1))))
    #expect(throws: SQLError.function("f")) {
      _ = try Routines().registering("f", function)
    }
  }

  @Test func `a body naming its own name over an existing one captures the old one`() throws {
    // `f() AS f() + 1` REPLACING a prior `f` is well-defined under early
    // binding: the new body captures the OLD `f` (the map before this
    // registration), so it computes `f_old() + 1` and terminates — no
    // recursion. With `f_old` = 0, `f_new()` = 0 + 1 = 1.
    let existing = Function(parameters: [], returns: .integer,
                            body: .literal(.integer(0)))
    let routines = try Routines().registering("f", existing)
    let call = Expression.call(name: "f", arguments: [])
    let recursive = Function(parameters: [], returns: .integer,
                             body: .binary(.add, call, .literal(.integer(1))))
    let redefined = try routines.registering("f", recursive)
    try numbers().expect("SELECT f() FROM N WHERE Id = 1",
                         yields: [[1]], routines: redefined)
  }

  @Test func `a body calling a prelude routine registers and runs`() throws {
    // `lowbit(n INTEGER) AS BITAND(n, 1)` calls the prelude BITAND. The capture
    // seeds `Routines.standard` under `self` — the SAME precedence the public
    // run/columns compose a query's routines with — so the body resolves BITAND
    // at registration exactly as an ordinary SELECT would, rather than faulting
    // `SQLError.function("BITAND")` for a built-in the query path can reach.
    let lowbit =
        Function(parameters: [Function.Parameter(name: "n", type: .integer)],
                 returns: .integer,
                 body: .call(name: "BITAND",
                             arguments: [.column("n"), .literal(.integer(1))]))
    let routines = try Routines().registering("lowbit", lowbit)
    // N.V is 7 (Id 1); BITAND(7, 1) = 1.
    try numbers().expect("SELECT lowbit(V) FROM N WHERE Id = 1",
                         yields: [[1]], routines: routines)
  }

  @Test func `a body calling a still-unknown routine faults at registration`() {
    // The capture is the prelude overlaid with `self`, NOT every routine: a
    // body naming a routine neither the prelude nor a prior registration binds
    // is still unresolved, faulting `SQLError.function` at registration — the
    // guard against over-merging masking a genuinely-unknown callee.
    let function = Function(parameters: [], returns: .integer,
                            body: .call(name: "nope", arguments: []))
    #expect(throws: SQLError.function("nope")) {
      _ = try Routines().registering("f", function)
    }
  }

  @Test func `a caller function shadows a like-named prelude routine in a body`() throws {
    // Precedence is standard-under-self: a caller registration of BITAND
    // shadows the prelude one in a later body's capture, so `lowbit(n) AS
    // BITAND(n, 1)` resolves the caller's BITAND (here returning a constant 9),
    // not the built-in bitwise AND.
    let bitand = Routine(returns: .integer, parameters: [.integer, .integer]) {
      _ in .integer(9)
    }
    let lowbit =
        Function(parameters: [Function.Parameter(name: "n", type: .integer)],
                 returns: .integer,
                 body: .call(name: "bitand",
                             arguments: [.column("n"), .literal(.integer(1))]))
    let routines = try Routines(["bitand": bitand])
        .registering("lowbit", lowbit)
    try numbers().expect("SELECT lowbit(V) FROM N WHERE Id = 1",
                         yields: [[9]], routines: routines)
  }

  @Test func `a defined body binds its callee at definition, not at call time`() throws {
    // The round-5 root case. `g` returns INTEGER 1; `f() AS g()` captures that
    // INTEGER `g`. Redefining `g` to a TEXT body shadows it for QUERIES, but
    // `f` closed over the old `g`, so `SELECT f()` still returns the INTEGER 1
    // — consistent with f's advertised INTEGER schema — while a top-level
    // `SELECT g()` sees the new TEXT `g` (query-level latest-wins unchanged).
    let g = Function(parameters: [], returns: .integer,
                     body: .literal(.integer(1)))
    let f = Function(parameters: [], returns: .integer,
                     body: .call(name: "g", arguments: []))
    let text = Function(parameters: [], returns: .text,
                        body: .literal(.string("x")))
    let routines = try Routines().registering("g", g)
        .registering("f", f).registering("g", text)
    try numbers().expect("SELECT f() FROM N WHERE Id = 1",
                         yields: [[1]], routines: routines)
    try numbers().expect("SELECT g() FROM N WHERE Id = 1",
                         yields: [["x"]], routines: routines)
  }

  @Test func `a body referencing a query parameter faults at registration`() {
    // A body's inputs are its declared parameters, not query bindings. `f() AS
    // CASE WHEN 1 = :p THEN 1 ELSE 0 END` reaches a `:parameter` through a CASE
    // guard, but a routine body is evaluated with only its argument record — the
    // caller's bindings never reach it — so `:p` would always be UNBOUND and
    // silently pick the ELSE branch. The registration rejects the `.bound`.
    let body =
        Expression.case([When(when: .bound(left: .literal(.integer(1)),
                                           op: .equal, parameter: "p"),
                              then: .literal(.integer(1)))],
                        else: .literal(.integer(0)))
    let function = Function(parameters: [], returns: .integer, body: body)
    #expect(throws:
        SQLError.argument("the body cannot reference a query parameter")) {
      _ = try Routines().registering("f", function)
    }
  }

  @Test func `a body with a bound-free CASE registers cleanly`() throws {
    // The rejection is of a `.bound` specifically, not of a CASE in a body: a
    // guard over the parameter (`CASE WHEN n = 7 THEN 1 ELSE 0 END`) registers
    // and computes — here yielding 1 for the matching argument (N.V is 7).
    let body =
        Expression.case([When(when: .comparison(left: .column("n"),
                                                op: .equal,
                                                right: .literal(.integer(7))),
                              then: .literal(.integer(1)))],
                        else: .literal(.integer(0)))
    let function =
        Function(parameters: [Function.Parameter(name: "n", type: .integer)],
                 returns: .integer, body: body)
    let routines = try Routines().registering("seven", function)
    try numbers().expect("SELECT seven(V) FROM N WHERE Id = 1",
                         yields: [[1]], routines: routines)
  }

  @Test func `a RETURNS DOUBLE body of a mixed CASE returns a double`() throws {
    // `f(n INTEGER) RETURNS DOUBLE AS CASE WHEN n = 7 THEN 1 ELSE 2.5 END`: the
    // body's results unify to `.double`, so it TYPES as double and the RETURNS
    // check passes. Called with N.V = 7 it takes the integer THEN `1`, which
    // the CASE coercion widens to `.double(1.0)` — the value now matches the
    // declared double return, not a bare `.integer(1)`.
    let body =
        Expression.case([When(when: .comparison(left: .column("n"),
                                                op: .equal,
                                                right: .literal(.integer(7))),
                              then: .literal(.integer(1)))],
                        else: .literal(.double(2.5)))
    let function =
        Function(parameters: [Function.Parameter(name: "n", type: .integer)],
                 returns: .double, body: body)
    let routines = try Routines().registering("choose", function)
    try numbers().expect("SELECT choose(V) FROM N WHERE Id = 1",
                         yields: [[1.0]], routines: routines)
  }
}
