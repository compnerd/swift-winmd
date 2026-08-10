// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

/// A single-relation resolution scope `T(d, x)` — `d` at combined ordinal `0`,
/// `x` at `1` — for lowering a window over a known slot layout.
private func scope() -> Scope {
  Scope([(Relation(name: "T"),
          Schema(width: 2, extent: 2, names: ["d", "x"],
                 types: [.integer, .integer], virtuals: []))])
}

// MARK: - Windowing resolution

/// A ranking window resolves to a `Windowing` whose `PARTITION BY` keys and
/// window `ORDER BY` lower to combined base-ordinal terms, and whose result
/// type is `.integer`. The `Windowed` surface then maps a collected window to
/// its appended output slot while an ordinary source column passes through to
/// its own slot — the run's resolution, before the executor lands.
struct WindowResolutionTests {
  @Test func `each ranking function types as an integer`() {
    #expect(WindowFunction.number.type == .integer)
    #expect(WindowFunction.rank.type == .integer)
    #expect(WindowFunction.dense.type == .integer)
  }

  @Test func `a window lowers its partition and order to source terms`() throws {
    let window = Expression.window(
        function: .number,
        spec: WindowSpec(partition: [.column(Column("d"))],
                         order: Order(keys: [Order.Key(column: Column("x"),
                                                       ascending: false)])))
    let windowing = try window.windowing(scope())
    #expect(windowing.function == .number)
    #expect(windowing.partition == [.slot(0)])
    #expect(windowing.order == [SortKey(term: .slot(1), ascending: false,
                                        column: nil)])
  }

  @Test func `an empty OVER lowers to no partition and no order`() throws {
    let window = Expression.window(function: .rank, spec: WindowSpec())
    let windowing = try window.windowing(scope())
    #expect(windowing.partition.isEmpty)
    #expect(windowing.order.isEmpty)
  }

  @Test func `an unbound window ORDER BY ordinal binds to a SELECT star column`()
      throws {
    // The `Query.expanded` prelude binds a window ORDER BY ordinal to its
    // projected expression before this lowering, except a `SELECT *`, whose
    // outputs are not named before the source scope resolves. A raw spec
    // resolved directly here carries the ordinal, so the lowering binds it to
    // the source column `SELECT *` projects at that position — ordinal 1 the
    // first source column `d` at combined ordinal `0` — on the run and validate
    // paths alike.
    let window = Expression.window(
        function: .number,
        spec: WindowSpec(order: Order(keys: [Order.Key(sort: .ordinal(1))])))
    let windowing = try window.windowing(scope())
    #expect(windowing.order == [SortKey(term: .slot(0), ascending: true,
                                        column: nil)])
  }

  @Test func `a window ORDER BY ordinal past the SELECT star columns faults`() {
    // The scope names two source columns, so ordinal 3 is out of range and
    // faults `.column` (42703), spelled as the ordinal — the same fault a
    // query-level out-of-range ordinal raises.
    let window = Expression.window(
        function: .number,
        spec: WindowSpec(order: Order(keys: [Order.Key(sort: .ordinal(3))])))
    #expect(throws: SQLError.column("3")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `the windowed surface maps a window to its appended slot`() throws {
    let window = Expression.window(
        function: .number,
        spec: WindowSpec(partition: [.column(Column("d"))]))
    // Source `T(d, x)` packed identically (slots 0, 1); the `Windowed` appends
    // the lone windowing as it first resolves it, landing at appended slot
    // `width + 0` = 2.
    let windowed = Windowed(scope(), [0: 0, 1: 1], width: 2)
    #expect(try windowed.resolve(window) == .slot(2))
    // A bare source column passes through to its own slot — a window preserves
    // cardinality, so no grouping rule bars it.
    #expect(try windowed.resolve(.column(Column("x"))) == .slot(1))
    // A compound over the window recurses, lowering the window leaf to its
    // appended slot and the literal to a constant.
    let compound = Expression.binary(.add, window, .literal(.integer(1)))
    #expect(try windowed.resolve(compound)
                == .binary(.add, .slot(2), .constant(.integer(1))))
  }

  @Test func `a deterministic window shares a slot, a stateful one does not`()
      throws {
    let ordered = WindowSpec(order: Order(keys: [Order.Key(column: Column("x"))]))

    // ROW_NUMBER is deterministic, so two occurrences share one appended slot.
    let deterministic = Expression.window(function: .number, spec: ordered)
    let shared = Windowed(scope(), [0: 0, 1: 1], width: 2)
    _ = try shared.resolve(deterministic)
    _ = try shared.resolve(deterministic)
    #expect(shared.windowings.count == 1)

    // FIRST_VALUE(tick()) reads a non-deterministic routine, so two occurrences
    // each take their own slot rather than collapsing to one.
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(0)
        }
    let stateful = Expression.window(
        function: .first(.call(name: "tick", arguments: [])),
        spec: ordered)
    let distinct = Windowed(scope(), [0: 0, 1: 1], width: 2)
    _ = try distinct.resolve(stateful, routines)
    _ = try distinct.resolve(stateful, routines)
    #expect(distinct.windowings.count == 2)
  }

  @Test func `a window is discovered inside a compound expression`() {
    let window = Expression.window(function: .number, spec: WindowSpec())
    #expect(Expression.binary(.add, window, .literal(.integer(1))).windowed)
    #expect(!Expression.column(Column("x")).windowed)
    var collected = Array<Expression>()
    Expression.binary(.add, window, window).collect(windows: &collected)
    // The same window written twice is collected once.
    #expect(collected == [window])
  }
}

// MARK: - Argument invariants (public AST)

/// A window function argument the parser's grammar cannot express — a
/// nonpositive `NTILE` bucket count or `NTH_VALUE` position, a negative
/// `LEAD`/`LAG` offset — faults where the window lowers (`windowing`), the
/// shared point compile reaches on the run and validate paths alike. So a query
/// built directly through the public AST, bypassing the parser's guards, cannot
/// drive the executor into a division by a zero bucket count, a subscript before
/// the partition start, or the `-Int.min` negation `LAG` forms.
struct WindowArgumentTests {
  private let ordered =
      WindowSpec(order: Order(keys: [Order.Key(column: Column("x"))]))

  @Test func `a zero NTILE bucket count faults at lowering`() {
    let window = Expression.window(function: .ntile(0), spec: ordered)
    #expect(throws:
        SQLError.state("22023", "NTILE requires a positive bucket count")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `a zero NTH_VALUE position faults at lowering`() {
    let window = Expression.window(
        function: .nth(.column(Column("x")), 0), spec: ordered)
    #expect(throws:
        SQLError.state("22023", "NTH_VALUE requires a positive position")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `a minimum LAG offset faults at lowering`() {
    let window = Expression.window(
        function: .lag(.column(Column("x")), offset: Int.min, default: nil),
        spec: ordered)
    #expect(throws:
        SQLError.state("22023", "LAG requires a nonnegative offset")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `a negative LEAD offset faults at lowering`() {
    let window = Expression.window(
        function: .lead(.column(Column("x")), offset: -1, default: nil),
        spec: ordered)
    #expect(throws:
        SQLError.state("22023", "LEAD requires a nonnegative offset")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `a negative frame offset is rejected`() {
    // The parser admits only nonnegative frame offsets, but a public AST can
    // build `.preceding(-1)`/`.following(-1)` — which run the bound the opposite
    // way — so the shared frame check rejects them. `reject(for:order:)`
    // validates the frame before the function's own frameability; a ROWS frame
    // reads no order-key types, so `order` is nil.
    for bound in [Frame.Bound.preceding(-1), .following(-1)] {
      let frame = Frame(unit: .rows, start: bound, end: .current)
      #expect(throws:
          SQLError.state("22023", "a window frame offset must be nonnegative")) {
        try frame.reject(for: .number, order: nil)
      }
    }
  }

  @Test func `an invalid frame bound ordering is rejected`() {
    // A directly built frame reaches the same validity checks a parsed one does.
    #expect(throws: SQLError.state(
        "42601", "a window frame cannot start at UNBOUNDED FOLLOWING")) {
      try Frame(unit: .rows, start: .tail, end: .current)
          .reject(for: .number, order: nil)
    }
    #expect(throws: SQLError.state(
        "42601", "a window frame cannot end at UNBOUNDED PRECEDING")) {
      try Frame(unit: .rows, start: .current, end: .head)
          .reject(for: .number, order: nil)
    }
  }
}

// MARK: - Ordinal provenance (public AST)

/// The output an ordinal named (`Order.Key.output`) is resolver-generated
/// provenance, not a public input: the setter is `internal`, so a key built
/// through a public initializer carries no provenance and only the resolver
/// stamps one. That keeps the index a valid projection ordinal by construction,
/// so `materialise` never reads an out-of-range projected column — and the
/// guard below keeps it total even against a future internal bug.
struct OrdinalProvenanceTests {
  @Test func `a public initializer carries no ordinal provenance`() {
    // Every public initializer constructs `output` as `nil`; there is no public
    // parameter to supply one, so a module-external caller building the AST —
    // an ordinal, a bare column, an expression key — cannot forge a provenance
    // the run path would trust as a projection index.
    #expect(Order.Key(sort: .ordinal(1)).output == nil)
    #expect(Order.Key(column: Column("x")).output == nil)
    #expect(Order.Key(sort: .expression(.column(Column("x"))),
                      ascending: false).output == nil)
  }

  @Test func `the resolver stamps the output an ordinal named`() throws {
    // The one producer of provenance: resolving a window ORDER BY ordinal
    // substitutes the projected expression and stamps the 0-based output it
    // came from. Ordinal 1 binds to the first output and records `0`.
    let spec = WindowSpec(order: Order(keys: [Order.Key(sort: .ordinal(1))]))
    let outputs = [Expression.column(Column("x")),
                   Expression.column(Column("d"))]
    let key = try spec.resolving(ordinals: outputs).order?.keys.first
    #expect(key?.sort == .expression(.column(Column("x"))))
    #expect(key?.output == 0)
  }

  @Test func `materialise skips an out-of-range provenance column`() {
    // Unreachable on real input — provenance is resolver-generated and always a
    // valid projection index — this exercises the total guard directly. A key
    // naming output 9 over a two-column projection hoists nothing and returns
    // rather than trapping on `projection[9]`.
    let stray = Windowing(function: .number, partition: [],
                          order: [SortKey(term: .apply(name: "tick",
                                                       arguments: []),
                                          ascending: true, column: 9)])
    let projection = [Term.slot(0), Term.slot(1)]
    let result = materialise([stray], projection, [], width: 2,
                             below: .values(rows: [], types: []))
    #expect(result.projection == projection)
    #expect(result.windowings == [stray])
  }
}
