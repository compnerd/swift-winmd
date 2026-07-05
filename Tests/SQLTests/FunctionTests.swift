// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

@Suite struct RoutineTests {
  @Test("a routine's return type defaults to integer")
  func defaultReturn() {
    #expect(Routine(parameters: []) { _ in .integer(0) }.returns == .integer)
  }

  @Test("a routine carries its declared return type")
  func declaredReturn() {
    #expect(Routine(returns: .text, parameters: []) { _ in .text("x") }
                .returns == .text)
  }

  @Test("a routine carries its declared parameter contract")
  func declaredParameters() {
    let routine = Routine(parameters: [.integer, .text]) { _ in .integer(0) }
    #expect(routine.parameters == [.integer, .text])
  }

  @Test("a routine is called to compute a value")
  func callable() throws {
    let double = Routine(parameters: [.integer]) { arguments in
      guard case let .integer(x) = arguments[0] else { return .null }
      return .integer(x * 2)
    }
    #expect(try double([.integer(21)]) == .integer(42))
  }

  @Test("a Routine literal registers its declared signature")
  func routineLiteral() {
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

  @Test("registering declares a signature, the return defaulting to integer")
  func registering() {
    let routines = Routines()
        .registering("t", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
        .registering("i", parameters: [.integer]) { _ in .integer(0) }
    #expect(routines["t"]?.returns == .text)
    #expect(routines["i"]?.returns == .integer)
  }

  @Test("the name subscript resolves case-insensitively")
  func lookup() {
    let routines: Routines =
        ["Tag": Routine(returns: .text, parameters: []) { _ in .text("x") }]
    #expect(routines["TAG"] != nil)
    #expect(routines["nope"] == nil)
  }

  @Test("the standard prelude declares BITAND over two integers")
  func standardBitand() {
    #expect(Routines.standard["bitand"]?.returns == .integer)
    #expect(Routines.standard["bitand"]?.parameters == [.integer, .integer])
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
  @Test("a defined call with too few arguments faults at the run path")
  func arityShort() throws {
    // A defined routine reaches the run path without a prior type-check, so its
    // arity is enforced in the call itself: `twice()` reads slot 0 of an empty
    // record, which would trap; the guard turns it into `SQLError.argument`.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice() FROM N WHERE Id = 1",
                         fails: .argument("takes 1 arguments"),
                         routines: routines)
  }

  @Test("a defined call with too many arguments faults at the run path")
  func arityLong() throws {
    // Extra arguments are not silently ignored: the arity guard rejects a call
    // wider than the declared parameters, the same `SQLError.argument` a native
    // routine's own count check raises.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V, V) FROM N WHERE Id = 1",
                         fails: .argument("takes 1 arguments"),
                         routines: routines)
  }

  @Test("registering a body of the wrong type faults against the RETURNS")
  func returnMismatch() {
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

  @Test("registering a body matching the RETURNS succeeds and runs")
  func returnMatch() throws {
    // A body whose derived type equals the declared result registers cleanly
    // and computes over its argument.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V) FROM N WHERE Id = 1",
                         yields: [[14]], routines: routines)
  }

  @Test("a NULL result is allowed against any declared return type")
  func returnNull() throws {
    // NULL is not a type — it propagates through any declared result — so a
    // body that yields NULL on a row (a NULL argument through its arithmetic)
    // does not violate the INTEGER contract the derivation checked.
    let routines = try Routines().registering("twice", twice())
    try numbers().expect("SELECT twice(V) FROM N WHERE Id = 2",
                         yields: [[nil]], routines: routines)
  }

  @Test("a duplicate parameter on the public path faults with the later name")
  func duplicateParameter() {
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

  @Test("registering a body calling an unregistered routine faults")
  func unresolvedCall() {
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

  @Test("a body calling an already-registered routine adopts its return type")
  func resolvedCall() throws {
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

  @Test("a defined call with a wrong-typed argument faults at the run path")
  func argumentType() throws {
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

  @Test("a defined call with a NULL argument is allowed and yields NULL")
  func argumentNull() throws {
    // NULL is not a type — it propagates through the body — so a NULL argument
    // bound to any declared parameter is admitted (exactly as `BITAND` returns
    // NULL on a NULL argument), and the identity body yields NULL.
    let routines = try Routines().registering("id", id())
    try numbers().expect("SELECT id(V) FROM N WHERE Id = 2",
                         yields: [[nil]], routines: routines)
  }

  @Test("a defined call with a correct-typed argument returns the value")
  func argumentMatch() throws {
    // A correct-typed argument passes the run-path type check and the identity
    // body returns it — the guard rejects only a definitively-wrong type.
    let routines = try Routines().registering("id", id())
    try numbers().expect("SELECT id(V) FROM N WHERE Id = 1",
                         yields: [[7]], routines: routines)
  }

  @Test("a body naming its own unregistered name faults as unresolved")
  func selfReference() {
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

  @Test("a body naming its own name over an existing one captures the old one")
  func selfShadowing() throws {
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

  @Test("a body calling a prelude routine registers and runs")
  func preludeCall() throws {
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

  @Test("a body calling a still-unknown routine faults at registration")
  func unknownCall() {
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

  @Test("a caller function shadows a like-named prelude routine in a body")
  func preludeShadowed() throws {
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

  @Test("a defined body binds its callee at definition, not at call time")
  func capturedCallee() throws {
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
}
