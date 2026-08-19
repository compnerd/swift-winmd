// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A `Parent` driving a join to `Child`. `Parent` is the smaller side (so the
/// reorder drives from it, its leaf the join's outer) sorted on `Pid` — a bound
/// `Parent.Pid = :parent` seeks that outer leaf — beside a non-sorted integer
/// `Px` for the unindexed-column push. `Child` is the inner side sorted on
/// `Cid` — a bound `Child.Cid = :child` rides the inner filter and seeks —
/// carrying an integer `Cn` and a text `Cs` for the cross-kind corners.
private func related() throws -> FixtureCatalog {
  try Catalog {
    Relation("Parent", ["Pid": .integer, "Px": .integer], sorted: "Pid") {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("Child",
             ["Cid": .integer, "Pid": .integer, "Cn": .integer, "Cs": .text],
             sorted: "Cid") {
      Row(1, 1, 100, "a")
      Row(2, 1, 200, "b")
      Row(3, 2, 300, "c")
    }
  }
}

/// A non-empty `L` beside an empty `R` — a cross product or non-equi join over
/// them yields no rows, so a residual over `L` alone must not fire.
private func crossed() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Lid": .integer, "Ln": .integer]) {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("R", ["Rid": .integer]) {
    }
  }
}

/// A base relation, a second relation, and a simple view `Empt` that yields no
/// rows (`Bn < 0` matches nothing) — a zero-output derived join side.
private func viewed() throws -> FixtureCatalog {
  try Catalog {
    Relation("Base", ["Bid": .integer, "Bn": .integer]) {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("Other", ["Oid": .integer]) {
      Row(1)
    }
    try View("Empt", "SELECT Bid, Bn FROM Base WHERE Bn < 0",
             as: ["Bid", "Bn"])
  }
}

/// A `Keys` relation joined to an empty `Texts` whose sort key is an integer
/// beside a text column `Ts` — the inner side is zero-output, so a residual
/// over it never runs.
private func mismatched() throws -> FixtureCatalog {
  try Catalog {
    Relation("Keys", ["Kid": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("Texts", ["Tid": .integer, "Ts": .text], sorted: "Tid") {
    }
  }
}

/// The incomparable-type fault an `integer` against a `character varying` pair
/// raises at run.
private let intVsText =
    SQLError.state("42804", "cannot compare integer with character varying")

/// Whether `plan` reaches a `.join` carrying a non-nil inner filter — the shape
/// `nest` leaves when a pushed-down conjunct (a throw-neutral bound equality
/// included) rides the inner leaf, applied while the executor materialises and
/// seeks the inner rows.
private func riding(_ plan: Plan) -> Bool {
  switch plan {
  case let .join(outer, _, _, _, _, _, filter):
    filter != nil || riding(outer)
  case let .select(_, source):
    riding(source)
  case let .project(_, source):
    riding(source)
  case let .sort(_, source):
    riding(source)
  case let .derived(_, sub, _, _):
    riding(sub)
  case let .product(left, right):
    riding(left) || riding(right)
  case let .outer(left, right, _, _):
    riding(left) || riding(right)
  case let .semijoin(left, right, _, _):
    riding(left) || riding(right)
  case let .apply(left, _, _, _, _, _):
    riding(left)
  case let .setop(_, left, right, _, _, _):
    riding(left) || riding(right)
  case let .limit(_, _, source), let .top(_, _, _, source),
       let .distinct(source), let .aggregate(_, _, source),
       let .window(_, source):
    riding(source)
  case .single, .values, .empty, .scan:
    false
  }
}

/// The optimised plan of `sql` against `catalog` under `bindings` — the same
/// compile → pushdown → optimise pipeline the run drives, so the pushed-down
/// bound conjunct rides exactly as it runs.
private func planned(_ catalog: borrowing FixtureCatalog, _ sql: String,
                     _ bindings: Bindings = [:]) throws -> Plan {
  let compiled = try catalog.compile(parse(sql))
  return try catalog.optimise(compiled.pushdown(bindings), bindings)
}

/// The rendered plan-tree lines of `sql` — the exact `EXPLAIN` output, built
/// under `bindings` so a bound seek renders as it runs.
private func lines(_ catalog: borrowing FixtureCatalog, _ sql: String,
                   _ bindings: Bindings = [:]) throws -> Array<String> {
  let context = Context(routines: .standard, bindings: bindings)
  return try catalog.render(catalog.plan(of: parse(sql), context), context)
}

// MARK: - Originals: a comparable bound equality reaches the seek

/// A bound `column = :parameter` whose column kind reconciles with the run
/// binding is throw-neutral — it cannot fault `42804` this run — so selection
/// pushdown rides it to the seek leaf below the join, exactly as it rides a
/// literal-keyed equality. The prior admit-then-lift fix reached the same seek
/// but through an unsound detour (push unsafe, lift later); this pushes only
/// the provably throw-neutral conjunct, so nothing is ever lifted.
struct BoundEqualitySeekTests {
  @Test func `an integer bound on a seekable outer key seeks the leaf`()
      throws {
    // O1: `Parent.Pid = :parent` above the join, `:parent` an integer against
    // the sorted `Pid`. The neutral conjunct rides to the Parent leaf and seeks
    // it — a seek visible in the plan.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Parent.Pid = :parent",
                           ["parent": .integer(1)])
    #expect(sought(plan))
    #expect(pushed(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid WHERE Parent.Pid = :parent",
                       yields: [[100], [200]],
                       bindings: ["parent": .integer(1)])
  }

  @Test func `the bound seek matches the literal seek shape`() throws {
    // The bound-keyed plan renders the same seeked scan the literal-keyed one
    // does — the parameter is resolved to the same integer boundary.
    let catalog = try related()
    let bound = try lines(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                   + "ON Parent.Pid = Child.Pid "
                                   + "WHERE Parent.Pid = :parent",
                          ["parent": .integer(1)])
    let literal = try lines(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                     + "ON Parent.Pid = Child.Pid "
                                     + "WHERE Parent.Pid = 1")
    #expect(bound == literal)
    #expect(bound.contains { $0.contains("seek") })
  }

  @Test func `an integer bound on the inner key rides the inner filter`()
      throws {
    // O2: `Child.Cid = :child` on the inner side rides the join's inner filter
    // and seeks the inner leaf per outer row — a filter riding the `.join`.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Child.Cid = :child",
                           ["child": .integer(2)])
    #expect(riding(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid WHERE Child.Cid = :child",
                       yields: [[200]], bindings: ["child": .integer(2)])
  }

  @Test func `a cross-kind bound over a matching join still faults`() throws {
    // O3: `Child.Cn = :p` with a text `:p` against the integer `Cn` is not
    // throw-neutral, so it stays the always-evaluated residual above the join.
    // The join matches, so the residual runs and faults `42804` — never a
    // silent empty.
    try related().expect("SELECT Child.Cn FROM Parent JOIN Child "
                         + "ON Parent.Pid = Child.Pid WHERE Child.Cn = :p",
                         fails: intVsText, bindings: ["p": .text("z")])
  }

  @Test func `an unbound parameter is UNKNOWN, empty, and never faults`()
      throws {
    // O5: `Parent.Pid = :missing` with no binding reads the parameter as NULL,
    // so every comparison is UNKNOWN and no row survives — an empty result, no
    // fault (the neutral push cannot introduce one).
    try related().empty("SELECT Child.Cn FROM Parent JOIN Child "
                        + "ON Parent.Pid = Child.Pid "
                        + "WHERE Parent.Pid = :missing")
  }

  @Test func `a NULL-bound parameter is UNKNOWN, empty, and never faults`()
      throws {
    // O5: the same, with the parameter explicitly bound to NULL.
    try related().empty("SELECT Child.Cn FROM Parent JOIN Child "
                        + "ON Parent.Pid = Child.Pid WHERE Parent.Pid = :p",
                        bindings: ["p": .null])
  }

  @Test func `an integer bound on an unindexed column pushes without a seek`()
      throws {
    // O6: `Parent.Px = :px` against the non-sorted integer `Px` is neutral, so
    // it pushes to the Parent leaf and filters there — no seek is available on
    // an unindexed column, but the rows are correct.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Parent.Px = :px",
                           ["px": .integer(20)])
    #expect(!sought(plan))
    #expect(pushed(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid WHERE Parent.Px = :px",
                       yields: [[300]], bindings: ["px": .integer(20)])
  }

  @Test func `a non-equality bound stays above the join`() throws {
    // O7: `Parent.Pid > :p` is barred — only an equality is throw-neutral
    // here — so it never seeks or rides; it stays the residual above the join.
    // The rows are still correct.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Parent.Pid > :p",
                           ["p": .integer(0)])
    #expect(!sought(plan))
    #expect(!riding(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid WHERE Parent.Pid > :p",
                       yields: [[100], [200], [300]],
                       bindings: ["p": .integer(0)])
  }

  @Test func `a bound BETWEEN stays above the join`() throws {
    // O7: a parameterised `BETWEEN` is not a bound equality, so it is never
    // neutral — it stays above the join and the rows are correct.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Parent.Pid BETWEEN :lo AND :hi",
                           ["lo": .integer(2), "hi": .integer(9)])
    #expect(!sought(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid "
                       + "WHERE Parent.Pid BETWEEN :lo AND :hi",
                       yields: [[300]],
                       bindings: ["lo": .integer(2), "hi": .integer(9)])
  }

  @Test func `a double bound widens against an integer column`() throws {
    // Precision: `Parent.Px = :px` with a double `:px` against the integer `Px`
    // is neutral — the kinds widen — so it pushes and filters (no integer seek
    // on a double key) and the promoted comparison admits the right row.
    let catalog = try related()
    let plan = try planned(catalog, "SELECT Child.Cn FROM Parent JOIN Child "
                                    + "ON Parent.Pid = Child.Pid "
                                    + "WHERE Parent.Px = :px",
                           ["px": .double(20.0)])
    #expect(!sought(plan))
    #expect(pushed(plan))
    try catalog.expect("SELECT Child.Cn FROM Parent JOIN Child "
                       + "ON Parent.Pid = Child.Pid WHERE Parent.Px = :px",
                       yields: [[300]], bindings: ["px": .double(20.0)])
  }
}

// MARK: - New corners: the three prior soundness holes must not fault

/// The redesign's proof obligation: a non-neutral bound conjunct is never
/// pushed, so a cross product, a simple view, or a cross-kind inner — the three
/// corners the admit-then-lift fix broke, each having no nest to lift from —
/// keeps the conjunct at its lazy-fault position above the barrier, where a
/// zero-output join never reaches it. No new `42804` fault.
struct BoundEqualityNoLiftTests {
  @Test func `a text bound over an empty cross product stays above`() throws {
    // N1: `L CROSS JOIN R WHERE L.Ln = :p` with a text `:p` against the integer
    // `Ln`, `R` empty. The cross product is empty. The non-neutral bound is not
    // pushed to `L`'s scan (which is non-empty), so it never evaluates — an
    // empty result, no fault. The admit-then-lift fix pushed it into the
    // cross-product input and, with no nest to lift from, faulted `L.Ln = 'z'`
    // on `L`'s rows.
    try crossed().empty("SELECT L.Ln FROM L CROSS JOIN R WHERE L.Ln = :p",
                        bindings: ["p": .text("z")])
  }

  @Test func `a text bound over an empty non-equi join stays above`() throws {
    // N1: the non-equi join analogue — no `match` to fold, no nest to lift.
    try crossed().empty("SELECT L.Ln FROM L JOIN R ON L.Lid < R.Rid "
                        + "WHERE L.Ln = :p", bindings: ["p": .text("z")])
  }

  @Test func `a text bound on a zero-output view column stays above`() throws {
    // N2: `Empt JOIN Other … WHERE Empt.Bn = :p` with a text `:p` against the
    // view's integer `Bn`, the view yielding no rows. The non-neutral bound is
    // not pushed into the derived body, so it stays above the derived leaf and
    // the empty view never reaches it — no fault. The admit-then-lift fix
    // pushed it into the simple view's body, which the outer optimiser could
    // not peel back out, and faulted.
    let catalog = try viewed()
    try catalog.empty("SELECT Empt.Bn FROM Empt JOIN Other "
                      + "ON Empt.Bid = Other.Oid WHERE Empt.Bn = :p",
                      bindings: ["p": .text("z")])
    // The bound stays above the derived leaf — it never rides the join.
    let plan = try planned(catalog, "SELECT Empt.Bn FROM Empt JOIN Other "
                                    + "ON Empt.Bid = Other.Oid "
                                    + "WHERE Empt.Bn = :p", ["p": .text("z")])
    #expect(!riding(plan))
  }

  @Test func `an integer bound on a text inner column stays above`() throws {
    // N3: `Keys JOIN Texts … WHERE Texts.Ts = :p` with an integer `:p` against
    // the inner's text `Ts` — `reconcile(.text, .integer)` is false, so it is
    // not neutral and never rides the inner filter. `Texts` is empty, so the
    // zero-output join never reaches the residual — empty, no fault.
    let catalog = try mismatched()
    try catalog.empty("SELECT Keys.Kid FROM Keys JOIN Texts "
                      + "ON Keys.Kid = Texts.Tid WHERE Texts.Ts = :p",
                      bindings: ["p": .integer(1)])
    let plan = try planned(catalog, "SELECT Keys.Kid FROM Keys JOIN Texts "
                                    + "ON Keys.Kid = Texts.Tid "
                                    + "WHERE Texts.Ts = :p", ["p": .integer(1)])
    #expect(!riding(plan))
  }
}
