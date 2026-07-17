// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Scalar-function tests

/// Routines with a demonstration scalar function `add`, which sums two integer
/// cells — standing in for the per-dialect decode functions a synthesis
/// projection calls. Built from `Routines.standard` so the prelude (`UPPER`,
/// `BITAND`, …) resolves here as it does at the engine's public entry points,
/// which seed the prelude by default; the string built-in `UPPER` folds a text
/// cell to upper case, so no demo `upper` is registered (it is protected).
private func routines() -> Routines {
  try! Routines.standard
    .registering("add", parameters: [.integer, .integer]) {
      arguments throws(SQLError) in
      guard arguments.count == 2,
          case let .integer(lhs) = arguments[0],
          case let .integer(rhs) = arguments[1] else {
        throw .argument("add expects two integer arguments")
      }
      return .integer(lhs + rhs)
    }
}

/// Runs `text` against the `People` catalog through the demonstration routines.
func engineFunctionRun(_ text: String) throws -> Array<Array<Value>> {
  try enginePeople().run(engineParse(text), routines())
}

struct EngineFunctionTests {
  @Test func `a registered function projects over a column`() throws {
    let rows = try engineFunctionRun("SELECT upper(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test func `a function projects beside a bare column`() throws {
    let rows =
        try engineFunctionRun("SELECT Id, upper(Name) FROM People WHERE Id = 3")
    #expect(rows == [[.integer(3), .text("CAROL")]])
  }

  @Test func `a function takes more than one column argument`() throws {
    let rows = try engineFunctionRun("SELECT add(Id, Age) FROM People WHERE Id = 2")
    // Bob: Id 2 + Age 25 = 27.
    #expect(rows == [[.integer(27)]])
  }

  @Test func `a function takes a literal argument`() throws {
    let rows = try engineFunctionRun("SELECT add(Id, 100) FROM People WHERE Id = 4")
    #expect(rows == [[.integer(104)]])
  }

  @Test func `a function call nests another function call`() throws {
    let rows =
        try engineFunctionRun("SELECT add(add(Id, 1), Age) FROM People WHERE Id = 5")
    // Eve: (5 + 1) + 25 = 31.
    #expect(rows == [[.integer(31)]])
  }

  @Test func `an unregistered function is reported`() throws {
    #expect(throws: SQLError.function("missing")) {
      try engineFunctionRun("SELECT missing(Name) FROM People")
    }
  }

  @Test func `a function rejecting its arguments reports the fault`() throws {
    // The run path does not statically type-check a call — it invokes the
    // routine, whose own kind check faults an INTEGER passed to the text
    // built-in UPPER.
    #expect(throws: SQLError.argument("UPPER requires a text argument")) {
      try engineFunctionRun("SELECT upper(Id) FROM People WHERE Id = 1")
    }
  }

  @Test func `a function call resolves its name case-insensitively`() throws {
    // The built-in `UPPER` resolves through the seeded prelude; the natural SQL
    // spelling UPPER resolves to it, as table and column identifiers do.
    let rows = try engineFunctionRun("SELECT UPPER(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test func `the prelude BITAND yields the bitwise AND of two integers`() throws {
    // BITAND ships in the prelude (`Routines.standard`): `routines()` never
    // registers it, yet the call resolves through the seeded prelude and folds
    // case-insensitively. 12 & 10 = 8; 6 & 3 = 2.
    #expect(try engineFunctionRun("SELECT BITAND(12, 10) FROM People WHERE Id = 1")
            == [[.integer(8)]])
    #expect(try engineFunctionRun("SELECT bitand(6, 3) FROM People WHERE Id = 1")
            == [[.integer(2)]])
  }

  @Test func `BITAND reports a function-argument fault, not a UNION arity error`() throws {
    // The wrong argument count is a function-argument fault (`.argument`), not
    // `.arity` — whose message is the UNION column-count mismatch.
    #expect(throws: SQLError.argument("BITAND takes two arguments")) {
      try engineFunctionRun("SELECT BITAND(1) FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.argument("BITAND requires integer arguments")) {
      try engineFunctionRun("SELECT BITAND('a', 1) FROM People WHERE Id = 1")
    }
  }

  @Test func `registering over a protected prelude routine is rejected`() throws {
    // BITAND is a protected standard built-in, so a caller cannot shadow it
    // through `registering`: the binding faults (SQLSTATE 42723) rather than
    // silently changing what a query naming BITAND computes. The prelude one
    // therefore always wins at the query's call site.
    #expect(throws: SQLError.state("42723",
        "'bitand' is a standard routine and cannot be redefined")) {
      try Routines.standard
          .registering("bitand", parameters: [.integer, .integer]) {
            _ throws(SQLError) in .integer(-1)
          }
    }
  }

  @Test func `routine names colliding only by case merge without trapping`() throws {
    // "tag" and "TAG" fold to one name; the registry merges them (the later-
    // sorting original spelling wins) instead of trapping on the duplicate.
    let routines: Routines =
        ["tag": Routine(returns: .text, parameters: [.text]) {
          _ in .text("lower")
        },
         "TAG": Routine(returns: .text, parameters: [.text]) {
          _ in .text("upper")
        }]
    let query = try engineParse("SELECT tag(Name) FROM People WHERE Id = 1")
    let rows = try enginePeople().run(query, routines)
    #expect(rows == [[.text("lower")]])
  }

  @Test func `a predicate filters on a scalar function call`() throws {
    // The documented contract: a predicate may call a registered function;
    // `upper(Name) = 'ALICE'` decodes the column before comparing.
    let rows =
        try engineFunctionRun("SELECT Id FROM People WHERE upper(Name) = 'ALICE'")
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a predicate compares a function result to an integer`() throws {
    let rows =
        try engineFunctionRun("SELECT Name FROM People WHERE add(Id, 10) = 12")
    #expect(rows == [[.text("Bob")]])
  }
}

// MARK: - Defined function (CREATE FUNCTION) tests

/// The routines with the DEFINED functions each `CREATE FUNCTION` in `defs`
/// registers, seeded from the standard prelude — the consumer's registration
/// path, folding a parsed `CREATE FUNCTION` into a `Routines`.
private func defining(_ defs: String...) throws -> Routines {
  var routines = Routines.standard
  for def in defs {
    guard case let .function(name, function) = try Statement(parsing: def)
    else {
      throw SQLError.incomplete(expected: "a CREATE FUNCTION statement")
    }
    routines = try routines.registering(name, function)
  }
  return routines
}

struct EngineDefinedFunctionTests {
  @Test func `a defined function evaluates its body over the arguments`() throws {
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    let rows =
        try enginePeople().run(engineParse("SELECT twice(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; twice(30) = 60.
    #expect(rows == [[.integer(60)]])
  }

  @Test func `a defined function binds each parameter to its argument by position`() throws {
    let routines =
        try defining("CREATE FUNCTION span(lo INTEGER, hi INTEGER) "
                         + "RETURNS INTEGER AS hi - lo")
    let rows =
        try enginePeople().run(engineParse("SELECT span(Id, Age) FROM People WHERE Id = 4"),
                         routines)
    // Dave: Id 4, Age 40; span(4, 40) = 36.
    #expect(rows == [[.integer(36)]])
  }

  @Test func `a defined function projects beside a bare column`() throws {
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let rows =
        try enginePeople().run(engineParse("SELECT Id, inc(Age) FROM People WHERE Id = 2"),
                         routines)
    // Bob: Id 2, Age 25; inc(25) = 26.
    #expect(rows == [[.integer(2), .integer(26)]])
  }

  @Test func `a defined function filters in a predicate`() throws {
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let rows =
        try enginePeople().run(engineParse("SELECT Name FROM People WHERE inc(Age) = 31"),
                         routines)
    // Alice and Carol are 30; inc(30) = 31.
    #expect(rows == [[.text("Alice")], [.text("Carol")]])
  }

  @Test func `a parameterless defined function yields its constant body`() throws {
    let routines =
        try defining("CREATE FUNCTION answer() RETURNS INTEGER AS 40 + 2")
    let rows =
        try enginePeople().run(engineParse("SELECT answer() FROM People WHERE Id = 1"),
                         routines)
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a defined function propagates a NULL argument through its body`() throws {
    // A NULL bound to a parameter propagates through the body's arithmetic (SQL
    // null propagation), so the result is NULL rather than a fault.
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let catalog = try Catalog {
      Relation("N", ["Id": .integer, "V": .integer]) {
        Row(1, nil)
      }
    }
    let rows = try catalog.run(engineParse("SELECT inc(V) FROM N WHERE Id = 1"),
                               routines)
    #expect(rows == [[.null]])
  }

  @Test func `a call with the wrong argument count faults with the declared arity`() throws {
    // The declared `parameters` contract is what the static type-check (the
    // `call` contract check, the schema path drives) validates a call against,
    // exactly as it does a native routine's signature — a wrong argument count
    // is a function-argument fault reporting the declared arity.
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    #expect(throws: SQLError.argument("twice takes 1 arguments")) {
      try enginePeople().columns(of: engineParse("SELECT twice(Id, Age) FROM People"),
                           routines: routines)
    }
  }

  @Test func `a call with a wrong argument kind faults against the parameter type`() throws {
    // A definitively-wrong argument type (text where an integer parameter is
    // declared) is rejected by the same `call` contract check.
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    #expect(throws: SQLError.argument("twice requires integer arguments")) {
      try enginePeople().columns(of: engineParse("SELECT twice(Name) FROM People"),
                           routines: routines)
    }
  }

  @Test func `typing reports the declared RETURNS of a defined function`() throws {
    // The result-schema walk types a `f(...)` call by the routine's declared
    // return type without running it, so a defined function's declared RETURNS
    // is what the output column reports.
    let routines =
        try defining("CREATE FUNCTION label(n INTEGER) RETURNS TEXT AS 'x'")
    let columns =
        try enginePeople().columns(of: engineParse("SELECT label(Id) AS L FROM People"),
                             routines: routines)
    #expect(columns.count == 1)
    #expect(columns[0] == OutputColumn(name: "L", type: .text))
  }

  @Test func `a defined function body naming an unknown parameter faults at define`() throws {
    // The body is lowered against its parameters at registration, so a reference
    // to a name the function does not declare faults there — the moment a
    // `CREATE FUNCTION` binds — not at each later call.
    #expect(throws: SQLError.column("m")) {
      _ = try defining("CREATE FUNCTION f(n INTEGER) RETURNS INTEGER AS m + 1")
    }
  }

  @Test func `a defined function body referencing a query parameter faults at define`() throws {
    // A body's inputs are its declared parameters, not query bindings: a routine
    // body is evaluated with only its argument record, so a `:parameter` (here
    // reached through a CASE guard) would always be UNBOUND and silently pick
    // the ELSE branch. Registration rejects the `.bound`.
    #expect(throws:
        SQLError.argument("the body cannot reference a query parameter")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS "
                           + "CASE WHEN 1 = :p THEN 1 ELSE 0 END")
    }
  }

  @Test func `a later defined function shadows an earlier one of the same name`() throws {
    // A later registration wins (the house rule the flat registry follows), so
    // the second `inc` — adding 100 — is the one a call resolves.
    let routines = try defining(
        "CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1",
        "CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 100")
    let rows =
        try enginePeople().run(engineParse("SELECT inc(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; the shadowing inc adds 100 → 130.
    #expect(rows == [[.integer(130)]])
  }

  @Test func `a body naming its own unregistered name faults as unresolved`() throws {
    // `f() RETURNS INTEGER AS f() + 1` with NO prior `f` early-binds against a
    // map without `f`, so the body's own call is unresolved: registration
    // faults `SQLError.function` — the unregistered-callee case — not a
    // self-reference one. Early binding admits no recursion; there is nothing
    // to bind to.
    #expect(throws: SQLError.function("f")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS f() + 1")
    }
  }

  @Test func `a self-referential redefinition captures the prior function`() throws {
    // `f() AS f() + 1` REPLACING a prior `f` is well-defined under early
    // binding: the new body captures the OLD `f` and computes `f_old() + 1`,
    // terminating. With `f_old()` = 0, `SELECT f()` returns 0 + 1 = 1.
    let routines = try defining(
        "CREATE FUNCTION f() RETURNS INTEGER AS 0",
        "CREATE FUNCTION f() RETURNS INTEGER AS f() + 1")
    let rows =
        try enginePeople().run(engineParse("SELECT f() FROM People WHERE Id = 1"),
                         routines)
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a body calling a different existing function still registers`() throws {
    // A body calling a distinct, already-registered routine early-binds it and
    // registers cleanly — the common composition case.
    let routines = try defining(
        "CREATE FUNCTION g(n INTEGER) RETURNS INTEGER AS n + 1",
        "CREATE FUNCTION f(n INTEGER) RETURNS INTEGER AS g(n) + 1")
    let rows =
        try enginePeople().run(engineParse("SELECT f(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; g(30) = 31, f(30) = g(30) + 1 = 32.
    #expect(rows == [[.integer(32)]])
  }

  @Test func `a body calling a prelude routine registers against empty routines`() throws {
    // Registered against EMPTY routines — NOT `defining`, which seeds the
    // prelude — a body calling BITAND still resolves it: registration merges
    // `Routines.standard` under the caller's routines (the run/columns
    // precedence), so `lowbit(n) AS BITAND(n, 1)` binds the built-in rather
    // than faulting `SQLError.function("BITAND")`.
    guard case let .function(name, function) =
        try Statement(parsing: "CREATE FUNCTION lowbit(n INTEGER) "
                          + "RETURNS INTEGER AS BITAND(n, 1)")
    else { throw SQLError.incomplete(expected: "a CREATE FUNCTION statement") }
    let routines = try Routines().registering(name, function)
    let rows =
        try enginePeople().run(engineParse("SELECT lowbit(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; BITAND(30, 1) = 0 (30 is even).
    #expect(rows == [[.integer(0)]])
    let odd =
        try enginePeople().run(engineParse("SELECT lowbit(Id) FROM People WHERE Id = 3"),
                         routines)
    // Id 3 is odd; BITAND(3, 1) = 1.
    #expect(odd == [[.integer(1)]])
  }

  @Test func `a body calling a still-unknown routine faults at registration`() throws {
    // Merging the prelude into the capture must not mask a genuinely-unknown
    // callee: a body naming `nope`, bound by neither the prelude nor a prior
    // registration, is still unresolved and faults `SQLError.function` at
    // registration — the guard against over-merging.
    #expect(throws: SQLError.function("nope")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS nope()")
    }
  }

  @Test func `a body binds its callee at definition, not at call time`() throws {
    // The round-5 root case at the parse level. `g` returns INTEGER 1; `f() AS
    // g()` captures that INTEGER `g`. Redefining `g` to a TEXT body shadows it
    // for QUERIES, but `f` closed over the old `g`, so `SELECT f()` still
    // returns the INTEGER 1 — consistent with f's advertised INTEGER schema —
    // while `SELECT g()` sees the new TEXT `g` (query-level latest-wins holds).
    let routines = try defining(
        "CREATE FUNCTION g() RETURNS INTEGER AS 1",
        "CREATE FUNCTION f() RETURNS INTEGER AS g()",
        "CREATE FUNCTION g() RETURNS TEXT AS 'x'")
    let captured =
        try enginePeople().run(engineParse("SELECT f() FROM People WHERE Id = 1"),
                         routines)
    #expect(captured == [[.integer(1)]])
    let latest =
        try enginePeople().run(engineParse("SELECT g() FROM People WHERE Id = 1"),
                         routines)
    #expect(latest == [[.text("x")]])
  }
}
