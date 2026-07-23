// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - View tests

struct EngineViewTests {
  @Test func `a view resolves and queries like a table`() throws {
    // `SELECT * FROM Adults` runs the view's `SELECT Id, Name FROM Parent
    // WHERE Id >= 2`, exposing the columns as `Key`/`Label`.
    let rows = try view("SELECT * FROM Adults")
    #expect(rows == [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ])
  }

  @Test func `a projection over a view selects the view's columns by name`() throws {
    try gallery().expect("SELECT Label FROM Adults", yields: [["Bee"], ["Cid"]])
  }

  @Test func `a WHERE over a view filters its rows`() throws {
    try gallery().expect("SELECT Label FROM Adults WHERE Key = 3",
                       yields: [["Cid"]])
  }

  @Test func `an ORDER BY over a view orders its rows`() throws {
    try gallery().expect("SELECT Label FROM Adults ORDER BY Label DESC",
                       yields: [["Cid"], ["Bee"]])
  }

  @Test func `a view whose definition is a join resolves and queries`() throws {
    // `Pairs` denormalises the `Parent`/`Child` foreign-key join; querying it
    // runs the inner join and exposes its two columns as `Parent`/`Kid`.
    let rows = try view("SELECT * FROM Pairs")
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a projection and filter over a join view selects across its columns`() throws {
    try gallery().expect("SELECT Kid FROM Pairs WHERE Parent = 'Ada'",
                       yields: [["Ann"], ["Amy"]])
  }

  @Test func `an unknown column of a view is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try view("SELECT Missing FROM Adults")
    }
  }

  @Test func `a SELECT * view over-declaring its columns is rejected at resolution`() throws {
    // `Parent` is two columns wide, but the view declares three. A `SELECT *`
    // has no statically known arity, so the parser admits the list; the engine
    // catches the mismatch at resolution rather than indexing past a row.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b", "c"])
    let catalog = EngineMemory(try family().catalog, views: ["Star": star])
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
      try catalog.run(parse("SELECT a FROM Star"))
    }
  }

  @Test func `a SELECT * view whose explicit list matches the width resolves`() throws {
    // The same `SELECT *` view declared with the right number of columns
    // resolves and queries — the backstop passes the well-formed view through.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b"])
    let catalog = EngineMemory(try family().catalog, views: ["Star": star])
    let rows = try catalog.run(parse("SELECT b FROM Star WHERE a = 1"))
    #expect(rows == [[.text("Ada")]])
  }

  @Test func `a view's definition is optimised — its seekable predicate seeks`() throws {
    // `Adults` is `SELECT Id, Name FROM Parent WHERE Id >= 2`, and `Parent` is
    // sorted on `Id`, so the view's sub-plan must seek that run rather than
    // scanning under a `Select`. Compile and optimise an outer query over the
    // view and inspect the `.derived` leaf: its sub-plan must reach a seeked
    // `.scan` (a non-nil seek) and carry no `.select` over a raw scan.
    let catalog = try gallery()
    let select = try parse("SELECT Key, Label FROM Adults")
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled, [:])
    let sub = try #require(derived(plan))
    #expect(sought(sub))
    #expect(!filters(sub))
  }
}

// MARK: - A view body must not correlate against the caller's row

/// A view is DEFINED independently of its call site, so its body must NOT bind
/// an unbound column to an enclosing query's row — even when the view is used
/// from inside a (correlated) subquery, whose compile threads its enclosing
/// scope as the correlation stack.
///
/// Folding the correlation stack into `Context` made the view-body compile path
/// inherit the caller's `outer`, so an unbound column in the view DEFINITION
/// (`WHERE k = 1`, where `k` is NOT in the view's own FROM) wrongly bound to a
/// caller's row when the enclosing relation happened to have a column `k`.
/// Clearing the correlation stack entering the view-body overlay restores the
/// fault: the view body cannot see the caller's row, so `k` is unbound at BOTH
/// compile and run.
struct EngineViewCorrelationTests {
  /// An outer `Env` carrying a column `k` a leaking view body could bind to,
  /// a source `Src` WITHOUT `k`, and a view `Bad` whose body references the
  /// unbound `k`.
  private func leaky() throws -> EngineMemory {
    let bad = try View(query: select("SELECT n FROM Src WHERE k = 1"),
                       columns: ["n"])
    return EngineMemory([
      "Env": FixtureRelation([EngineField(name: "k", type: .integer)],
                               [[.integer(1)]] as Array<Array<Value>>),
      "Src": FixtureRelation([EngineField(name: "n", type: .integer)],
                             [[.integer(7)]] as Array<Array<Value>>),
    ], views: ["Bad": bad])
  }

  @Test func `a view body under a subquery does not bind the caller's column`()
      throws {
    // `SELECT k FROM Env WHERE EXISTS (SELECT n FROM Bad)` — the EXISTS
    // subquery compiles with `Env` as its enclosing scope, so the view `Bad`
    // resolves under a non-nil correlation stack. Its body `WHERE k = 1` names
    // `k`, absent from its own FROM (`Src`); it must fault as unbound, NOT
    // bind to `Env.k`.
    try leaky().expect(
        "SELECT k FROM Env WHERE EXISTS (SELECT n FROM Bad)",
        fails: .column("k"))
  }

  @Test func `the view faults at compile under a subquery, not only at run`()
      throws {
    // Schema ↔ run parity: the STRICT schema pass faults the view body's
    // unbound `k` too, rather than binding it to the caller — the leak the fold
    // introduced would have compiled a schema for a view that cannot run.
    let query = try parse(
        "SELECT k FROM Env WHERE EXISTS (SELECT n FROM Bad)")
    #expect(throws: SQLError.self) {
      _ = try leaky().columns(of: query, validate: true)
    }
  }

  @Test func `a valid view under a subquery still resolves and runs`() throws {
    // Control: a LEGITIMATE view (its body self-contained) used from a nested
    // subquery still resolves and runs — clearing the view body's correlation
    // stack does not disturb a well-formed view. `Good` reads `Src` (one row),
    // so the EXISTS holds for every `Env` row.
    let good = try View(query: select("SELECT n FROM Src"), columns: ["n"])
    let catalog = EngineMemory([
      "Env": FixtureRelation([EngineField(name: "k", type: .integer)],
                               [[.integer(1)], [.integer(2)]]
                                   as Array<Array<Value>>),
      "Src": FixtureRelation([EngineField(name: "n", type: .integer)],
                             [[.integer(7)]] as Array<Array<Value>>),
    ], views: ["Good": good])
    try catalog.expect(
        "SELECT k FROM Env WHERE EXISTS (SELECT n FROM Good) ORDER BY k",
        yields: [[1], [2]])
  }

  @Test func `a genuine correlation to the caller still works`() throws {
    // Guard: clearing the VIEW body's correlation must not break a legitimately
    // correlated subquery. The EXISTS subquery itself references the outer
    // `Env.k` (`Src.n = k`), a genuine correlation — it still lowers and runs
    // per outer row. Only the `k = 1` outer row keeps the EXISTS (Src has n = 1
    // there), so the result is that row alone.
    let catalog = EngineMemory([
      "Env": FixtureRelation([EngineField(name: "k", type: .integer)],
                               [[.integer(1)], [.integer(2)]]
                                   as Array<Array<Value>>),
      "Src": FixtureRelation([EngineField(name: "n", type: .integer)],
                             [[.integer(1)]] as Array<Array<Value>>),
    ])
    try catalog.expect(
        "SELECT k FROM Env WHERE EXISTS (SELECT n FROM Src WHERE n = k) " +
        "ORDER BY k",
        yields: [[1]])
  }

  // MARK: - schema(of:) view-body derivation must not correlate either

  /// The `schema(of:)` seam — the view-body SCHEMA/type derivation `scope(of:)`
  /// drives, resolving a `FROM <view>`'s relations to their types — entered the
  /// view-body overlay via `scoping([:]).visiting(name)` WITHOUT clearing the
  /// caller's correlation stack, the ONE view-body body-entry the prior round
  /// missed. So when a view whose DEFINITION references a column absent from its
  /// own FROM had its schema derived while under a correlated subquery whose
  /// outer relation HAS that column, the type-derivation bound the unbound
  /// column OUTWARD to the caller's row rather than faulting — disagreeing with
  /// the compile/run path `resolve`/`overlay` now clear. Routing every body-
  /// entry through `Context.body(_:)` (which appends `uncorrelated()`) closes
  /// it: `schema(of:)` faults the unbound column, consistent with compile/run.

  /// An outer `Env(k)` a leaking view PROJECTION could bind to, a source `Src`
  /// WITHOUT `k`, and a view `Proj` whose body PROJECTS the unbound `k` — so its
  /// SCHEMA (the projection's type) is what a leak would derive from the caller.
  private func leaked() throws -> EngineMemory {
    let proj = try View(query: select("SELECT k AS m FROM Src"),
                        columns: ["m"])
    return EngineMemory([
      "Env": FixtureRelation([EngineField(name: "k", type: .integer)],
                               [[.integer(1)]] as Array<Array<Value>>),
      "Src": FixtureRelation([EngineField(name: "n", type: .integer)],
                             [[.integer(7)]] as Array<Array<Value>>),
    ], views: ["Proj": proj])
  }

  /// A correlation stack whose NEAREST enclosing scope is `Env(k)` — the
  /// context a nested subquery's schema derivation runs under, so a leaking
  /// `schema(of:)` could bind an unbound view-projection column to `Env.k`. It
  /// nests a scope built from `Env`'s own schema (derived off the catalog),
  /// exactly as `compile`/`columns` thread an enclosing scope into a subquery.
  private func enclosing(_ catalog: borrowing EngineMemory) throws -> Context {
    let schema = try catalog.schema(of: Relation(name: "Env"), Context())
    return Context().nesting(under: Scope([(Relation(name: "Env"), schema)]))
  }

  @Test
  func `schema of a view under a correlated scope does not bind the caller`()
      throws {
    // Directly exercise the `schema(of:)` seam in ISOLATION: derive the scope
    // of `SELECT m FROM Proj` under a correlation stack whose enclosing scope
    // is `Env(k)`. `scope(of:)` calls `schema(of: Proj)`, which enters the
    // view body to type its projection `k` — absent from `Proj`'s own FROM
    // (`Src`). It must fault `k` as unbound, NOT bind it to the enclosing
    // `Env.k`. This is the seam the run/compile path (`resolve`/`overlay`)
    // clears elsewhere but `schema(of:)` did NOT until routed through `body`.
    let catalog = try leaked()
    let target = try select("SELECT m FROM Proj").first
    let context = try enclosing(catalog)
    var raised: SQLError?
    do {
      _ = try catalog.scope(of: target, context)
    } catch let fault {
      raised = fault
    }
    #expect(raised == .column("k"))
  }

  @Test
  func `schema of a valid view under a correlated scope still derives`()
      throws {
    // Control: a well-formed view whose projection is self-contained still has
    // its schema derived under the SAME correlated scope — clearing the schema
    // path's correlation stack does not disturb a legitimate view. `Fine`
    // projects `n` (in its own `Src`), so `scope(of:)` derives cleanly.
    let fine = try View(query: select("SELECT n AS m FROM Src"),
                        columns: ["m"])
    let catalog = EngineMemory([
      "Env": FixtureRelation([EngineField(name: "k", type: .integer)],
                               [[.integer(1)]] as Array<Array<Value>>),
      "Src": FixtureRelation([EngineField(name: "n", type: .integer)],
                             [[.integer(7)]] as Array<Array<Value>>),
    ], views: ["Fine": fine])
    let target = try select("SELECT m FROM Fine").first
    let context = try enclosing(catalog)
    // Eager rather than `#expect(throws:)` — a borrowed `~Escapable` catalog
    // cannot be captured by the assertion's escaping closure.
    _ = try catalog.scope(of: target, context)
  }

  @Test func `a view projecting an unbound column faults consistently`()
      throws {
    // End-to-end parity control: running `SELECT m FROM Proj` (outside any
    // correlation) faults the unbound projection `k` too, so the schema seam's
    // fault under a correlated scope AGREES with the plain run — schema ↔ run.
    try leaked().expect("SELECT m FROM Proj", fails: .column("k"))
  }
}

/// The sub-plan of the first `.derived` leaf reachable from `plan`, or `nil`.
func derived(_ plan: Plan) -> Plan? {
  switch plan {
  case let .derived(_, sub, _, _):
    sub
  case let .select(_, source):
    derived(source)
  case let .project(_, source):
    derived(source)
  case let .sort(_, source):
    derived(source)
  case let .product(left, right):
    derived(left) ?? derived(right)
  case let .outer(left, right, _, _):
    derived(left) ?? derived(right)
  case let .semijoin(left, right, _, _):
    derived(left) ?? derived(right)
  case let .apply(left, _, _, _, _, _):
    derived(left)
  case let .setop(_, left, right, _, _, _):
    derived(left) ?? derived(right)
  case let .limit(_, _, source):
    derived(source)
  case let .distinct(source):
    derived(source)
  case let .aggregate(_, _, source):
    derived(source)
  case .single, .empty, .scan, .join:
    nil
  }
}

/// Whether `plan` reaches a `.scan` carrying a non-nil seek.
func sought(_ plan: Plan) -> Bool {
  switch plan {
  case let .scan(_, _, seek):
    seek != nil
  case let .select(_, source):
    sought(source)
  case let .project(_, source):
    sought(source)
  case let .sort(_, source):
    sought(source)
  case let .derived(_, sub, _, _):
    sought(sub)
  case let .product(left, right):
    sought(left) || sought(right)
  case let .join(outer, _, _, _, _, _, _):
    // A pushed-down key seeks the join's OUTER leaf, so a seek can live inside
    // the join rather than only atop a bare scan.
    sought(outer)
  case let .outer(left, right, _, _):
    sought(left) || sought(right)
  case let .semijoin(left, right, _, _):
    sought(left) || sought(right)
  case let .apply(left, _, _, _, _, _):
    sought(left)
  case let .setop(_, left, right, _, _, _):
    sought(left) || sought(right)
  case let .limit(_, _, source):
    sought(source)
  case let .distinct(source):
    sought(source)
  case let .aggregate(_, _, source):
    sought(source)
  case .single, .empty:
    false
  }
}

/// Whether `plan` wraps a raw (unseeked) `.scan` in a `.select` — the
/// un-optimised shape the fix eliminates from a view's sub-plan.
func filters(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .scan(_, _, nil)):
    true
  case let .select(_, source):
    filters(source)
  case let .project(_, source):
    filters(source)
  case let .sort(_, source):
    filters(source)
  case let .derived(_, sub, _, _):
    filters(sub)
  case let .product(left, right):
    filters(left) || filters(right)
  case let .outer(left, right, _, _):
    filters(left) || filters(right)
  case let .semijoin(left, right, _, _):
    filters(left) || filters(right)
  case let .apply(left, _, _, _, _, _):
    filters(left)
  case let .setop(_, left, right, _, _, _):
    filters(left) || filters(right)
  case let .limit(_, _, source):
    filters(source)
  case let .distinct(source):
    filters(source)
  case let .aggregate(_, _, source):
    filters(source)
  case .single, .empty, .scan, .join:
    false
  }
}

/// Whether a single-relation filter rides below a `join` or `product` boundary —
/// the shape selection pushdown produces (a `.select` or a seeked `.scan` inside
/// a join's outer operand or a product's arm), as opposed to a `WHERE` left
/// floating atop the whole chain.
func pushed(_ plan: Plan) -> Bool {
  switch plan {
  case let .join(outer, _, _, _, _, _, _):
    sought(outer) || floating(outer) || pushed(outer)
  case let .product(left, right):
    sought(left) || floating(left) || pushed(left) || sought(right)
        || floating(right) || pushed(right)
  case let .outer(left, right, _, _):
    sought(left) || floating(left) || pushed(left) || sought(right)
        || floating(right) || pushed(right)
  case let .semijoin(left, right, _, _):
    sought(left) || floating(left) || pushed(left)
        || sought(right) || floating(right) || pushed(right)
  case let .apply(left, _, _, _, _, _):
    sought(left) || floating(left) || pushed(left)
  case let .select(_, source):
    pushed(source)
  case let .project(_, source):
    pushed(source)
  case let .sort(_, source):
    pushed(source)
  case let .derived(_, sub, _, _):
    pushed(sub)
  case let .setop(_, left, right, _, _, _):
    pushed(left) || pushed(right)
  case let .limit(_, _, source):
    pushed(source)
  case let .distinct(source):
    pushed(source)
  case let .aggregate(_, _, source):
    pushed(source)
  case .single, .empty, .scan:
    false
  }
}

/// Whether `plan` is (or reaches through unary operators) a `.select` — a filter
/// standing over a source.
func floating(_ plan: Plan) -> Bool {
  switch plan {
  case .select:
    true
  case let .project(_, source):
    floating(source)
  case let .sort(_, source):
    floating(source)
  case let .derived(_, sub, _, _):
    floating(sub)
  case let .limit(_, _, source):
    floating(source)
  default:
    false
  }
}

/// Whether `plan` reaches a `.join` node — the index-nested-loop/hash join path,
/// as opposed to a residual `.product` filtered by the ON predicate.
func joined(_ plan: Plan) -> Bool {
  switch plan {
  case .join:
    true
  case let .select(_, source):
    joined(source)
  case let .project(_, source):
    joined(source)
  case let .sort(_, source):
    joined(source)
  case let .limit(_, _, source):
    joined(source)
  case let .distinct(source):
    joined(source)
  case let .derived(_, sub, _, _):
    joined(sub)
  case let .product(left, right):
    joined(left) || joined(right)
  case let .outer(left, right, _, _):
    joined(left) || joined(right)
  case let .semijoin(left, right, _, _):
    joined(left) || joined(right)
  case let .apply(left, _, _, _, _, _):
    joined(left)
  case let .setop(_, left, right, _, _, _):
    joined(left) || joined(right)
  case let .aggregate(_, _, source):
    joined(source)
  case .single, .empty, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing directly over a `.product` — the
/// residual product-under-select the streaming path fuses and filters row by
/// row rather than materialising whole.
func residue(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .product):
    true
  case let .select(_, source):
    residue(source)
  case let .project(_, source):
    residue(source)
  case let .sort(_, source):
    residue(source)
  case let .limit(_, _, source):
    residue(source)
  case let .distinct(source):
    residue(source)
  case let .derived(_, sub, _, _):
    residue(sub)
  case let .product(left, right):
    residue(left) || residue(right)
  case let .join(outer, _, _, _, _, _, _):
    residue(outer)
  case let .outer(left, right, _, _):
    residue(left) || residue(right)
  case let .semijoin(left, right, _, _):
    residue(left) || residue(right)
  case let .apply(left, _, _, _, _, _):
    residue(left)
  case let .setop(_, left, right, _, _, _):
    residue(left) || residue(right)
  case let .aggregate(_, _, source):
    residue(source)
  case .single, .empty, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing directly over ANOTHER `.select`
/// over a `.product` — the WHERE-above-a-separate-ON-gate shape the barrier
/// preserves (the outer `select` the `WHERE`, the inner the residual `ON`
/// gate), as opposed to one fused `.select(ON AND WHERE, product)`.
func separated(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .select(_, .product)):
    true
  case let .select(_, source):
    separated(source)
  case let .project(_, source):
    separated(source)
  case let .sort(_, source):
    separated(source)
  case let .limit(_, _, source):
    separated(source)
  case let .distinct(source):
    separated(source)
  case let .derived(_, sub, _, _):
    separated(sub)
  case let .product(left, right):
    separated(left) || separated(right)
  case let .join(outer, _, _, _, _, _, _):
    separated(outer)
  case let .outer(left, right, _, _):
    separated(left) || separated(right)
  case let .semijoin(left, right, _, _):
    separated(left) || separated(right)
  case let .apply(left, _, _, _, _, _):
    separated(left)
  case let .setop(_, left, right, _, _, _):
    separated(left) || separated(right)
  case let .aggregate(_, _, source):
    separated(source)
  case .single, .empty, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing over ANOTHER `.select` over a
/// `.join` — the WHERE-above-a-leftover-ON-gate shape the always-barrier rule
/// preserves for a pure-equi `ON` whose extra equi key `nest` leaves gating
/// over the hash join (the outer `select` the `WHERE`, the inner the leftover
/// match), as opposed to one fused `.select(match AND WHERE, join)`.
func stacked(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .select(_, .join)):
    true
  case let .select(_, source):
    stacked(source)
  case let .project(_, source):
    stacked(source)
  case let .sort(_, source):
    stacked(source)
  case let .limit(_, _, source):
    stacked(source)
  case let .distinct(source):
    stacked(source)
  case let .derived(_, sub, _, _):
    stacked(sub)
  case let .product(left, right):
    stacked(left) || stacked(right)
  case let .join(outer, _, _, _, _, _, _):
    stacked(outer)
  case let .outer(left, right, _, _):
    stacked(left) || stacked(right)
  case let .semijoin(left, right, _, _):
    stacked(left) || stacked(right)
  case let .apply(left, _, _, _, _, _):
    stacked(left)
  case let .setop(_, left, right, _, _, _):
    stacked(left) || stacked(right)
  case let .aggregate(_, _, source):
    stacked(source)
  case .single, .empty, .scan:
    false
  }
}

// MARK: - Selection-pushdown tests

/// A join catalog whose inner `Child` relation tallies its row reads, plus a
/// view `Kin` over the `Parent`/`Child` join — to prove a `WHERE` over the view
/// prunes the join's inputs BEFORE the join runs rather than after. The counter
/// rides the `Parent` relation (sorted on `Id`), so a pushed seekable key reads
/// fewer of its rows regardless of the inner join strategy.
private func counted() throws -> (catalog: EngineMemory, reads: EngineCounter) {
  let reads = EngineCounter()
  let parent = [
    EngineField(name: "Id", type: .integer),
    EngineField(name: "Name", type: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    EngineField(name: "Pid", type: .integer),
    EngineField(name: "Kid", type: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(3), .text("Cody")],
  ] as Array<Array<Value>>

  let kin = try View(query: select("""
      SELECT Parent.Id, Parent.Name, Child.Kid FROM Parent
        JOIN Child ON Child.Pid = Parent.Id
      """), columns: ["Key", "Name", "Kid"])
  let catalog =
      EngineMemory([
        "Parent": FixtureRelation(parent, parents, sorted: 0, counter: reads),
        "Child": FixtureRelation(child, children),
      ], views: ["Kin": kin])
  return (catalog, reads)
}

/// A catalog for pushing a filter through a UNION view's arms: two relations
/// whose shared output column `Key` sits at DIFFERENT body ordinals — `Alpha`
/// has it first (sorted, so seekable), `Beta` last (unsorted) — exposed by a
/// `Both` view as one column. A `WHERE Key = ?` over the view must rebase PER
/// arm (each arm maps `Key` to its own body slot), pushing below every arm's
/// projection and seeking inside the `Alpha` arm.
private func spanned() throws -> EngineMemory {
  let alpha = [
    EngineField(name: "Key", type: .integer),
    EngineField(name: "Tag", type: .text),
  ]
  let alphas = [
    [.integer(1), .text("a1")],
    [.integer(2), .text("a2")],
    [.integer(3), .text("a3")],
  ] as Array<Array<Value>>

  let beta = [
    EngineField(name: "Tag", type: .text),
    EngineField(name: "Key", type: .integer),
  ]
  let betas = [
    [.text("b1"), .integer(1)],
    [.text("b2"), .integer(2)],
  ] as Array<Array<Value>>

  // Arm 1 projects Alpha.Key (body slot 0, seekable) then Tag; arm 2 projects
  // Beta.Key (body slot 1, unseekable) then Tag — the same output `Key` at
  // differing body slots.
  let both = try View(query: select("""
      SELECT Key, Tag FROM Alpha UNION ALL SELECT Key, Tag FROM Beta
      """), columns: ["Key", "Tag"])
  return EngineMemory([
    "Alpha": FixtureRelation(alpha, alphas, sorted: 0),
    "Beta": FixtureRelation(beta, betas),
  ], views: ["Both": both])
}

/// Whether `plan` reaches a `.union` every arm of which carries a filter pushed
/// below its projection — a seeked scan or a `.select` over its scan inside each
/// arm's body, the per-arm rebase this fix enables.
private func injected(_ plan: Plan) -> Bool {
  switch plan {
  case let .setop(_, left, right, _, _, _):
    (sought(left) || floating(left)) && (sought(right) || floating(right))
  case let .select(_, source):
    injected(source)
  case let .project(_, source):
    injected(source)
  case let .sort(_, source):
    injected(source)
  case let .limit(_, _, source):
    injected(source)
  case let .distinct(source):
    injected(source)
  case let .derived(_, sub, _, _):
    injected(sub)
  case let .product(left, right):
    injected(left) || injected(right)
  case let .outer(left, right, _, _):
    injected(left) || injected(right)
  case let .semijoin(left, right, _, _):
    injected(left) || injected(right)
  case let .apply(left, _, _, _, _, _):
    injected(left)
  case let .join(outer, _, _, _, _, _, _):
    injected(outer)
  case let .aggregate(_, _, source):
    injected(source)
  case .single, .empty, .scan:
    false
  }
}

struct EnginePushdownTests {
  @Test func `a single-relation WHERE conjunct rides below the join`() throws {
    // `WHERE Parent.Name = 'Ada'` references only the outer relation, so it
    // pushes to the Parent leaf inside the join rather than filtering the whole
    // product afterwards — `pushed` sees a filter within the join's outer.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(pushed(plan))
  }

  @Test func `pushdown down a seekable outer key seeks that leaf inside the join`() throws {
    // `WHERE Parent.Id = 2` is seekable; pushed to the Parent leaf it becomes a
    // seek inside the join's outer, not a scan-then-filter atop the product.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Id = 2
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(sought(plan))
    #expect(pushed(plan))
  }

  @Test func `a trailing seekable conjunct survives a rebuilt three-term AND`() throws {
    // Pushdown flattens a single-table filter through `conjuncts` and rebuilds
    // it via `conjunction`. A right-leaning rebuild would bury the trailing
    // `Id = 5` under a nested AND, hidden from `seek` (which inspects only a
    // top-level AND's two immediate children); the left-leaning rebuild keeps it
    // the immediate RHS, as the parser produced it, so the sort-key seek
    // survives the three-term AND.
    let catalog = EngineMemory([
      "T": FixtureRelation([
        EngineField(name: "Name", type: .text),
        EngineField(name: "Age", type: .integer),
        EngineField(name: "Id", type: .integer),
      ], [
        [.text("a"), .integer(1), .integer(5)],
        [.text("b"), .integer(2), .integer(6)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT Name FROM T WHERE Name <> 'x' AND Age > 0 AND Id = 5
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(sought(plan))
  }

  @Test func `a seekable conjunct grouped after an unsafe one does not bypass its throw`() throws {
    // The left fold rebuilds `(1 / x) = 0 AND (name <> 'z' AND id < 0)` — parsed
    // as `A AND (B AND C)` — into `((A AND B) AND C)`, promoting the seekable
    // `id < 0` to the top-level RHS `seek` inspects. On an id-sorted table whose
    // `id < 0` run is empty, seeking that run drops every row before the earlier
    // `(1 / x) = 0` division runs, suppressing the throw the scan owes. `seek`
    // seeks a conjunct only when the residual is safe, so the unsafe division
    // residual bars the seek: the plan scans, and it raises.
    let catalog = EngineMemory([
      "T": FixtureRelation([
        EngineField(name: "x", type: .integer),
        EngineField(name: "name", type: .text),
        EngineField(name: "id", type: .integer),
      ], [
        [.integer(0), .text("a"), .integer(5)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT id FROM T WHERE (1 / x) = 0 AND (name <> 'z' AND id < 0)
        """)

    // The unsafe `(1 / x) = 0` residual bars the `id < 0` seek — the plan scans.
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!sought(plan))

    // …and the scan raises the division rather than seeking past the empty run.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `pushdown preserves the join's result`() throws {
    // The pushed plan must return exactly the un-pushed join's rows.
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """,
        yields: [["Ann"], ["Amy"]])
  }

  @Test func `a non-key predicate on the joined-in relation still uses the join`() throws {
    // `WHERE Parent.Name <> 'zz'` references only the joined-in `Parent`, so
    // pushdown wraps that inner leaf as `Select(_, Scan(Parent))` before the
    // join folds it in. `nest` must look through that pushed filter and still
    // form a `Join` — not fall back to a residual product filtered by the ON
    // predicate (O(left × filtered-right)).
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))

    // …and it returns the correct rows: every child with a matching parent,
    // the joined-in predicate keeping all of them (no parent is named 'zz').
    try family().expect("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """,
        yields: [["Ann", "Ada"], ["Amy", "Ada"], ["Bob", "Bee"]])
  }

  @Test func `a spanning WHERE leaves the join path with a residual above it`() throws {
    // `WHERE Parent.Name <> Child.Name` references BOTH joined relations, so it
    // descends no further than the product and stays as a residual. The ON
    // match must remain adjacent to the product — folded in with the spanning
    // conjunct — so `nest` still finds it and forms a `Join`, keeping the
    // spanning predicate as a `Select` ABOVE the join rather than degrading to a
    // filtered Cartesian `product`.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
    #expect(floating(plan))

    // …and it returns the join's rows filtered by the spanning predicate: every
    // matched pair survives, none sharing a name across the two relations.
    try family().expect("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """,
        yields: [["Ann", "Ada"], ["Amy", "Ada"], ["Bob", "Bee"]])
  }

  @Test func `a WHERE over a join view prunes its rows before the join runs`() throws {
    // `Kin` is the Parent/Child join; `WHERE Key = 2` over it must push INTO the
    // view's sub-plan and seek Parent to the single matching row before joining,
    // so only that parent's rows are read — not the whole relation.
    let (culled, pruned) = try counted()
    let rows = try culled.run(parse("SELECT Kid FROM Kin WHERE Key = 2"))
    #expect(rows == [[.text("Bob")]])

    // The un-pushed baseline: the same view with no `WHERE` reads every parent
    // row — three.
    let (whole, full) = try counted()
    _ = try whole.run(parse("SELECT Kid FROM Kin"))
    #expect(full.reads == 3)

    // Pushed, the seek reads the one matching parent — a single row.
    #expect(pruned.reads == 1)
  }

  @Test func `the pushed view result matches the unfiltered view filtered late`() throws {
    // Running the view then filtering must agree with the pushed plan.
    let (catalog, _) = try counted()
    let all = try catalog.run(parse("SELECT Key, Kid FROM Kin"))
    let culled = all.filter { $0[0] == .integer(2) }.map { [$0[1]] }
    let filtered =
        try catalog.run(parse("SELECT Kid FROM Kin WHERE Key = 2"))
    #expect(filtered == culled)
  }

  @Test func `a slotless predicate stays above the join and skips an empty product`() throws {
    // `WHERE (1 / 0) = 0` reads no slots, so it must stay at the product level
    // and run per pair — not ride down to the left input. `B` is empty, so the
    // join's product is empty and the throwing expression is never evaluated;
    // the query returns no rows. Pushed to the left, it would run once per left
    // row and raise `SQLError.divide`.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "y", type: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / 0) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a throwing single-side predicate stays above the join, skips an empty product`() throws {
    // `WHERE (1 / A.x) = 0` reads only `A`'s slot but CAN throw (division), so —
    // like a slotless throwing predicate — it must stay at the product level, not
    // ride down to `A`. `B` is empty, so the product is empty and the division is
    // never evaluated; the query returns no rows. Pushed to `A` (x = 0) it would
    // divide by zero and raise `SQLError.divide`.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "y", type: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `an unsafe conjunct bars a later safe one from suppressing its throw`() throws {
    // `WHERE (1 / A.x) = 0 AND A.x <> 0`: left-to-right, the division runs first
    // and raises on the matching pair (`A.x = 0` joined to `B.y = 0`). The safe
    // `A.x <> 0` must NOT ride down to `A` — doing so would drop the row before
    // the division runs, silently returning no rows. The earlier unsafe conjunct
    // is an ordering barrier, so the query raises as the un-pushed `AND` would.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "y", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("""
          SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0 AND A.x <> 0
          """))
    }
  }

  @Test func `a lifted inner filter keeps its place before a later unsafe residual`() throws {
    // `WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0`: left-to-right, the
    // false `Parent.Name` check short-circuits before the division on the
    // matching pair (Child.x = 0). `Parent.Name = 'nope'` is a single-side inner
    // filter that nest lifts out of the join — it must stay BEFORE the unsafe
    // division in the residual, not be appended after it, or the division runs
    // first and raises. The matching Parent is named 'other', so the row is
    // excluded with no throw.
    let catalog = EngineMemory([
      "Child": FixtureRelation([EngineField(name: "Pid", type: .integer),
                         EngineField(name: "x", type: .integer)],
                        [[.integer(1), .integer(0)]] as Array<Array<Value>>),
      "Parent": FixtureRelation([EngineField(name: "Id", type: .integer),
                          EngineField(name: "Name", type: .text)],
                         [[.integer(1), .text("other")]]
                             as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT Child.x FROM Child JOIN Parent ON Parent.Id = Child.Pid
          WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a WHERE over a UNION view pushes into every arm's projection`() throws {
    // `Both` unions `Alpha` and `Beta`, whose shared `Key` output column sits at
    // DIFFERING body slots. `WHERE Key = 2` must rebase PER ARM — the union root
    // fails a single pre-rebased filter — pushing below each arm's projection
    // and seeking the sorted `Alpha` arm.
    let catalog = try spanned()
    let select = try parse("SELECT Tag FROM Both WHERE Key = 2")
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(injected(plan))
    #expect(sought(plan))

    // …and the rows are exactly the union filtered late: `a2` from Alpha and
    // `b2` from Beta.
    let rows = try catalog.run(select)
    #expect(rows == [[.text("a2")], [.text("b2")]])
  }

  @Test func `a view's throwing projection term is not suppressed by a pushed filter`() throws {
    // The view projects `1 / z`, which raises on the `z = 0` row. `derive`
    // evaluates every projected column for every view row, so `SELECT id FROM V
    // WHERE id <> 0` raises even though `id <> 0` would exclude that row —
    // pushing `id <> 0` below the view's Project would filter the row first and
    // silently skip the division, so a view whose projection can throw is never
    // pushed into.
    let t = [EngineField(name: "id", type: .integer),
             EngineField(name: "z", type: .integer)]
    let rows = [[.integer(0), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT id, 1 / z FROM T"),
                        columns: ["id", "q"])
    let catalog = EngineMemory(["T": FixtureRelation(t, rows)], views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("SELECT id FROM V WHERE id <> 0"))
    }
  }

  @Test func `an unsafe outer conjunct bars a later push into a view`() throws {
    // `V` is `SELECT x FROM T` with `T.x` sorted and a single `x = 0` row.
    // `SELECT x FROM V WHERE (1 / x) = 0 AND x = 1`: left-to-right, the division
    // runs on the `x = 0` row and raises. The safe seekable `x = 1` must NOT push
    // into the view past the earlier unsafe `(1 / x) = 0` — doing so would SEEK
    // the view (`T.x` sorted) to `x = 1`, dropping the `x = 0` row before the
    // outer division ever runs, silently returning no rows. The unsafe outer
    // conjunct is an ordering barrier, so the query raises as the un-pushed `AND`
    // would.
    let t = [EngineField(name: "x", type: .integer)]
    let rows = [[.integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x FROM T"), columns: ["x"])
    let catalog = EngineMemory(["T": FixtureRelation(t, rows, sorted: 0)],
                         views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("SELECT x FROM V WHERE (1 / x) = 0 AND x = 1"))
    }
  }

  @Test func `a nullable conjunct is not pushed below a later unsafe conjunct`() throws {
    // `WHERE A.x = 1 AND (1 / B.y) = 0`: the evaluator's `AND` does not short-
    // circuit, so on the matching pair (A.x NULL, B.y = 0) the UNKNOWN left
    // still runs the right, and the division raises. The safe `A.x = 1`
    // references a slot, so a NULL there makes it UNKNOWN — pushing it to `A`'s
    // scan would drop the A.x-NULL row before the join, so the later unsafe
    // `(1 / B.y) = 0` never runs and the throw the `AND` owes is suppressed. A
    // nullable conjunct must NOT ride past a LATER unsafe conjunct, so `A.x = 1`
    // stays a product-level residual and the query raises.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.null, .integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "y", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .integer(0)]] as Array<Array<Value>>),
    ])
    let select = try parse("""
        SELECT A.x FROM A JOIN B ON A.k = B.k
          WHERE A.x = 1 AND (1 / B.y) = 0
        """)

    // `A.x = 1` is nullable and precedes the unsafe division, so it is NOT
    // pushed to the `A` leaf — it floats at the product level.
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!pushed(plan))
    #expect(floating(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a nullable conjunct is not pushed into a view below a later unsafe one`() throws {
    // `V` exposes safe columns `x` and `y`. `SELECT x FROM V WHERE x = 1 AND
    // (1 / y) = 0`: the `AND` does not short-circuit, so on the (x NULL, y = 0)
    // row the UNKNOWN left still runs the division, which raises. Pushing the
    // nullable `x = 1` into the view would drop the x-NULL row before the outer
    // division runs, suppressing the throw. A nullable conjunct must NOT be
    // injected past a LATER unsafe outer conjunct, so `x = 1` stays outer and
    // the query raises.
    let t = [EngineField(name: "x", type: .integer),
             EngineField(name: "y", type: .integer)]
    let rows = [[.null, .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = EngineMemory(["T": FixtureRelation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE x = 1 AND (1 / y) = 0")

    // `x = 1` is nullable and precedes the unsafe division, so it is NOT
    // injected into the view — it floats above the derived leaf.
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(floating(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a slotless bound conjunct is not pushed into a view below a later unsafe one`() throws {
    // A `.bound` predicate compares against a run-time `:parameter` and reads no
    // slot, yet it is UNKNOWN when the parameter is unbound (or bound to NULL).
    // `SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0` with `:missing`
    // unbound: the outer `AND` does not short-circuit, so on the (y = 0) row the
    // UNKNOWN left still runs the division, which raises. Injecting the slotless
    // `1 = :missing` into the view would drop every row first, suppressing the
    // throw. A bound conjunct is nullable despite reading no slot, so it stays
    // outer and the query raises.
    let t = [EngineField(name: "x", type: .integer),
             EngineField(name: "y", type: .integer)]
    let rows = [[.integer(1), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = EngineMemory(["T": FixtureRelation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0")

    // `1 = :missing` is a slotless bound predicate, hence nullable; it precedes
    // the unsafe division, so it is NOT injected into the view — it floats above
    // the derived leaf.
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(floating(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a throwing WHERE is not evaluated for a pair an UNKNOWN ON rejects`() throws {
    // `A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0` where `V` is a derived view,
    // so `nest` cannot fold the product into a `Join`. On the `A` row with a
    // NULL `k` and `x = 0`, the ON match is UNKNOWN — the join forms no pair for
    // it — but `evaluate(.and)` does not short-circuit, so folding the match and
    // WHERE into one AND would evaluate `(1 / 0)` and raise. Keeping the match a
    // separate inner gate drops that pair before the WHERE runs, so the query
    // does not raise: the matched `x = 1` row fails `(1 / 1) = 0`, leaving no
    // rows.
    let a = [EngineField(name: "x", type: .integer), EngineField(name: "k", type: .integer)]
    let catalog = EngineMemory([
      "A": FixtureRelation(a, [[.integer(1), .integer(1)],
                        [.integer(0), .null]] as Array<Array<Value>>),
      "T": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
    ], views: ["V": try View(query: select("SELECT k FROM T"),
                             columns: ["k"])])
    let select =
        try parse("SELECT A.x FROM A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0")

    // The UNKNOWN-ON pair (A.k NULL) is dropped by the match gate before the
    // division runs, so the query returns rows rather than raising.
    #expect(try catalog.run(select) == [])
  }
}

// MARK: - Set-op view type probe must not pollute the runtime plan memo

/// The set-op column-type unification `compile` derives for a `UNION`/`EXCEPT`/
/// `INTERSECT` view body runs a SCHEMA-ONLY projection PROBE (to learn which
/// columns the set operation widens). That probe lowers any nested correlated
/// subquery under the `.caller` id space and — before the fix — recorded the
/// subquery's per-outer-row PLAN into the SHARED runtime memo. Recording is
/// first-writer-wins, so a later CALLER whose own correlated subquery has the
/// SAME AST and correlation (`(SELECT Val FROM S WHERE S.Id = T.Id)` over a
/// same-shaped outer `T`) reused the VIEW body's plan — resolving `S` against
/// the view's BASE table, not the caller's own CTE `S`. The probe must derive
/// against an ISOLATED throwaway memo so it records nothing, letting each
/// caller resolve its subquery against its OWN base.
private func shadowed() throws -> EngineMemory {
  try Catalog {
    // The shared driver `T`, referenced by the view body AND the caller, so the
    // correlated subquery's outer `T.Id` binds at the SAME ordinal in both — an
    // identical `Correlation`, hence an identical plan-memo key.
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
    }
    // The BASE `S` the VIEW body's `(SELECT Val FROM S …)` resolves against —
    // `Id` at ordinal 0, `Val` at ordinal 1. A caller CTE named `S` shadows it
    // with the columns in the OPPOSITE order (`Val` at 0, `Id` at 1), so the
    // view's compiled plan — which projects ordinal 1 and filters ordinal 0 —
    // reads the WRONG cells if reused against the caller's CTE: it would
    // project the CTE's `Id` (ordinal 1) rather than its `Val` (ordinal 0).
    Relation("S", ["Id": .integer, "Val": .integer]) {
      Row(1, 1000)
      Row(2, 2000)
    }
    // A set-operation view whose LEFT arm holds a correlated scalar subquery
    // `(SELECT Val FROM S WHERE S.Id = T.Id)` — the SAME AST the caller uses.
    // Compiling its body runs the `.setop` widened-column type probe, which
    // lowers that subquery under `.caller`; the probe must NOT record its plan.
    try View("V", """
        SELECT (SELECT Val FROM S WHERE S.Id = T.Id) AS c FROM T
          UNION ALL
        SELECT 0 AS c FROM T
        """, as: ["c"])
  }
}

struct EngineSetopViewMemoTests {
  @Test func `a set-op view type probe does not capture a caller's subquery`()
      throws {
    // The caller shadows base `S` with a CTE `S` whose columns are in the
    // OPPOSITE order (`Val, Id`) and runs the IDENTICAL correlated subquery
    // `(SELECT Val FROM S WHERE S.Id = T.Id)` over `T`. It also references the
    // set-op view `V`, whose body compile runs the widened-type probe over the
    // same subquery AST first. With the probe isolated, the caller's subquery
    // resolves against ITS CTE `S` at ITS ordinals, projecting `Val` ∈ {7, 8};
    // a probe that polluted the shared memo would make the caller reuse the
    // view's plan (base `S` ordinals — project ordinal 1, filter ordinal 0),
    // which over the swapped CTE projects `Id` ∈ {1, 2} (or mis-filters).
    let rows = try shadowed().run(Statement(parsing:
        """
        WITH S (Val, Id) AS (SELECT 7, 1 UNION ALL SELECT 8, 2)
          SELECT (SELECT Val FROM S WHERE S.Id = T.Id) AS c
            FROM T JOIN V ON V.c = 0 GROUP BY T.Id ORDER BY c
        """))
    #expect(rows == [[.integer(7)], [.integer(8)]])
  }
}

