// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport
import func SQLTestSupport.parse

// MARK: - VALUES

/// The ISO `VALUES (…), …` table value constructor is a first-class query body
/// (`Query.Body.values`). These tests confirm it parses to that node, yields
/// its rows in order, names the default `column1, column2, …` outputs, works
/// standalone and as a derived table, preserves duplicate rows, composes with a
/// set operation, and faults on a cross-row arity mismatch.
struct ValuesTests {
  /// A minimal catalog for the FROM-less `VALUES` runs — the constructor names
  /// no relation, so its single one-element relation is never scanned; the run
  /// still needs a catalog to borrow.
  private func store() throws -> EngineMemory {
    try Catalog {
      Relation("Unused", ["a": .integer]) {
        Row(1)
      }
    }
  }

  /// The `SQLError` running a hand-built `query` against a fresh store raises,
  /// or nil — the eager form the borrowed `~Escapable` catalog needs (it cannot
  /// be captured by an `#expect(throws:)` closure).
  private func fault(running query: Query) -> SQLError? {
    do {
      _ = try store().run(query, .standard)
      return nil
    } catch let error as SQLError {
      return error
    } catch {
      return nil
    }
  }

  /// The `SQLError` deriving (validate) a hand-built `query`'s columns against
  /// a fresh store raises, or nil.
  private func fault(deriving query: Query) -> SQLError? {
    do {
      _ = try store().columns(of: query, routines: .standard, validate: true)
      return nil
    } catch let error as SQLError {
      return error
    } catch {
      return nil
    }
  }

  // MARK: - Node shape

  @Test func `VALUES parses to a first-class values node`() throws {
    // `VALUES (1, 2), (3, 4)` parses directly to the `.values` body — one row
    // per parenthesised tuple, holding the bare element expressions in source
    // order — rather than a `UNION ALL` of FROM-less selects.
    let query = try parse(query: "VALUES (1, 2), (3, 4)")
    guard case let .values(rows) = query.body else {
      Issue.record("expected a values body")
      return
    }
    #expect(rows == [[.literal(.integer(1)), .literal(.integer(2))],
                     [.literal(.integer(3)), .literal(.integer(4))]])
    // Carrier-free — a bare constructor carries no query-level tail.
    #expect(query.carriers.isEmpty)
  }

  @Test func `a single-row VALUES is a one-row values node`() throws {
    // With one row the node holds a single tuple.
    let query = try parse(query: "VALUES (1, 2)")
    guard case let .values(rows) = query.body else {
      Issue.record("expected a values body")
      return
    }
    #expect(rows == [[.literal(.integer(1)), .literal(.integer(2))]])
  }

  // MARK: - Standalone

  @Test func `a standalone VALUES yields its rows in order`() throws {
    try store().expect("VALUES (1, 2), (3, 4)", yields: [[1, 2], [3, 4]])
  }

  @Test func `a single-row VALUES yields that one row`() throws {
    try store().expect("VALUES (1, 2)", yields: [[1, 2]])
  }

  @Test func `VALUES yields a text column`() throws {
    try store().expect("VALUES (1, 'a'), (2, 'b')",
                       yields: [[1, "a"], [2, "b"]])
  }

  @Test func `VALUES preserves duplicate rows with no dedup`() throws {
    // The desugar is `UNION ALL`, so a repeated row is kept, not collapsed.
    try store().expect("VALUES (1, 2), (1, 2), (3, 4)",
                       yields: [[1, 2], [1, 2], [3, 4]])
  }

  @Test func `VALUES row order is source order`() throws {
    try store().expect("VALUES (3), (1), (2)", yields: [[3], [1], [2]])
  }

  // MARK: - Default column names

  @Test func `VALUES names its default columns column1, column2, …`() throws {
    // The default output names are the ISO `column1, column2, …`; a derived
    // table over the constructor exposes them for selection.
    try store().expect("SELECT column1 FROM (VALUES (5, 6), (7, 8)) AS t",
                       yields: [[5], [7]])
    try store().expect("SELECT column2 FROM (VALUES (5, 6), (7, 8)) AS t",
                       yields: [[6], [8]])
  }

  @Test func `VALUES default names appear in the result schema`() throws {
    let columns = try store().columns(of:
        parse(query: "VALUES (1, 'a'), (2, 'b')"), routines: .standard)
    #expect(columns.map(\.name) == ["column1", "column2"])
  }

  // MARK: - Derived table

  @Test func `VALUES is a derived-table source in FROM`() throws {
    try store().expect("SELECT * FROM (VALUES (1, 2), (3, 4)) AS t",
                       yields: [[1, 2], [3, 4]])
  }

  @Test func `a derived VALUES projects a qualified column`() throws {
    try store().expect("SELECT t.column1 FROM (VALUES (10), (20)) AS t",
                       yields: [[10], [20]])
  }

  @Test func `a derived VALUES filters through a WHERE`() throws {
    try store().expect(
        "SELECT column1 FROM (VALUES (1), (2), (3)) AS t WHERE column1 > 1",
        yields: [[2], [3]])
  }

  // MARK: - Type unification

  @Test func `a mixed numeric VALUES column unifies to double`() throws {
    // VALUES desugars to a `UNION ALL`, so a column's type unifies across every
    // arm through the set-operation type fold (the ISO rule a `UNION` follows),
    // NOT the first arm alone. A column mixing integer and double widens to
    // double, and the integer arm's value is coerced to that unified type.
    // `VALUES (1), (2.5)`'s column1 is thus a double throughout, `1.0` then
    // `2.5`, regardless of the arm order.
    let columns = try store().columns(of:
        parse(query: "VALUES (1), (2.5)"), routines: .standard)
    #expect(columns.map(\.type) == [.double])
    try store().expect("VALUES (1), (2.5)", yields: [[1.0], [2.5]])
  }

  @Test func `a VALUES with a leading double column types double`() throws {
    // Written double-first, the same column is a double throughout — the
    // cross-arm unification is order-independent, so integer-then-double and
    // double-then-integer both widen to double and coerce the integer arm.
    let columns = try store().columns(of:
        parse(query: "VALUES (2.5), (1)"), routines: .standard)
    #expect(columns.map(\.type) == [.double])
    try store().expect("VALUES (2.5), (1)", yields: [[2.5], [1.0]])
  }

  // MARK: - Set-operation composition

  @Test func `VALUES composes under a UNION`() throws {
    // A `VALUES` primary is a query, so it composes on either side of a set
    // operator; the outer `UNION` dedups the shared row.
    try store().expect(
        "VALUES (1), (2) UNION VALUES (2), (3)",
        yields: [[1], [2], [3]])
  }

  @Test func `VALUES mixes with a TABLE arm across a UNION ALL`() throws {
    try roster().expect(
        "SELECT Age FROM People WHERE Id = 1 UNION ALL VALUES (99)",
        yields: [[30], [99]])
  }

  // MARK: - Parenthesised-query contexts

  @Test func `VALUES is a scalar subquery`() throws {
    // `(VALUES (1))` is a query, so it is a first-class scalar subquery: a
    // one-row one-column constructor yields that single scalar, exactly as
    // `(SELECT …)` does. The parse must route the parenthesised `VALUES` to the
    // query parser, not the value-expression parser — here nested as the
    // element of an outer `VALUES` row.
    let query = try parse(query: "VALUES ((VALUES (1)))")
    guard case let .values(rows) = query.body, let row = rows.first,
          row.count == 1 else {
      Issue.record("expected a single-element VALUES row")
      return
    }
    guard case .subquery = row[0] else {
      Issue.record("expected a scalar subquery expression")
      return
    }
    try store().expect("VALUES ((VALUES (1)))", yields: [[1]])
  }

  @Test func `VALUES is an IN-subquery`() throws {
    // `IN (VALUES (…), (…))` tests membership over the constructor's rows — a
    // query subquery, not a bare value list. The parenthesised `VALUES` must
    // route to the query parser so it is one subquery, not two row literals.
    let query = try parse(query:
        "SELECT Id FROM People WHERE Id IN (VALUES (1), (2))")
    guard case let .select(select) = query.body,
          case .within? = select.predicate else {
      Issue.record("expected an IN-subquery predicate")
      return
    }
    try roster().expect(
        "SELECT Id FROM People WHERE Id IN (VALUES (1), (2))",
        yields: [[1], [2]])
  }

  @Test func `VALUES is a quantified-comparison subquery`() throws {
    // `= ANY (VALUES (…), (…))` compares against the constructor's rows — the
    // quantified path always parses a parenthesised query, so a `VALUES`
    // primary composes there as `(SELECT …)` does.
    try roster().expect(
        "SELECT Id FROM People WHERE Age = ANY (VALUES (30), (40))",
        yields: [[1], [3], [4]])
  }

  @Test func `VALUES is an EXISTS subquery`() throws {
    // `EXISTS (VALUES (1))` tests the constructor's non-emptiness — a one-row
    // constructor is always non-empty, so the EXISTS holds for every outer row.
    try roster().expect(
        "SELECT Id FROM People WHERE EXISTS (VALUES (1)) ORDER BY Id",
        yields: [[1], [2], [3], [4], [5]])
  }

  // MARK: - CTE body

  @Test func `VALUES is a CTE body`() throws {
    // A `WITH t(a, b) AS (VALUES …)` binds the constructor's rows under the
    // CTE's declared columns, so the trailing query reads them by name.
    let rows = try store().run(Statement(parsing: """
        WITH t(a, b) AS (VALUES (1, 2), (3, 4)) SELECT b, a FROM t
        """), .standard)
    #expect(rows == [[.integer(2), .integer(1)],
                     [.integer(4), .integer(3)]])
  }

  @Test func `a VALUES CTE body infers the default column names`() throws {
    // Without an explicit column list the CTE inherits the constructor's ISO
    // default `column1, column2, …` output names.
    let rows = try store().run(Statement(parsing: """
        WITH t AS (VALUES (5, 6)) SELECT column1, column2 FROM t
        """), .standard)
    #expect(rows == [[.integer(5), .integer(6)]])
  }

  @Test func `an incompatible mixed VALUES column faults`() throws {
    // A column mixing text and integer has no common type, so the set-operation
    // type fold VALUES desugars through rejects it — the same operand fault a
    // `UNION` of irreconcilable arms raises.
    try store().expect("VALUES ('a'), (1)",
                       fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a NULL VALUES arm unifies with a typed arm`() throws {
    // A constant-NULL arm constrains nothing, so it unifies with the other
    // arm's type rather than faulting — `NULLIF('a', 'a')` is NULL, so the
    // column takes the integer arm's type and the constructor runs, the NULL
    // arm yielding NULL and the integer arm its value.
    let columns = try store().columns(of:
        parse(query: "VALUES (NULLIF('a', 'a')), (1)"), routines: .standard)
    #expect(columns.map(\.type) == [.integer])
    try store().expect("VALUES (NULLIF('a', 'a')), (1)",
                       yields: [[nil], [1]])
  }

  // MARK: - Faults

  @Test func `VALUES faults on a cross-row arity mismatch`() throws {
    // Every row must construct the same number of columns; a wider or narrower
    // later row is an ISO arity error.
    try store().expect("VALUES (1, 2), (3)", fails: .arity(2, 1))
    try store().expect("VALUES (1), (2, 3)", fails: .arity(1, 2))
  }

  @Test func `an empty VALUES row faults`() throws {
    // Each row must have at least one element; a `VALUES ()` is not a row.
    #expect(throws: SQLError.self) {
      _ = try parse(query: "VALUES ()")
    }
  }

  // MARK: - FROM-less query-expression tails

  @Test func `a single-row VALUES takes a query-expression ORDER BY`() throws {
    // A FROM-less primary is a single-row query, and the enclosing query
    // expression's trailing ORDER BY orders that result — a no-op on one row,
    // but the key still resolves. With no source column to order on, the key
    // binds an ordinal or an output alias (the only ISO keys here): `ORDER BY 1`
    // and `ORDER BY column1` both name the sole output. The schema derive agrees
    // — the run compiles and validates the tail identically (run ≡ columns(of:)).
    try store().expect("VALUES (1) ORDER BY 1", yields: [[1]])
    try store().expect("VALUES (1) ORDER BY column1", yields: [[1]])
    let columns = try store().columns(of:
        parse(query: "VALUES (1) ORDER BY 1"), routines: .standard,
        validate: true)
    #expect(columns.map(\.name) == ["column1"])
  }

  @Test func `a FROM-less OFFSET or FETCH pages the single row`() throws {
    // OFFSET/FETCH slices the one-row result exactly as it slices a FROM'd one:
    // skipping the row or fetching zero rows yields the empty result.
    try store().empty("VALUES (1) OFFSET 1 ROWS")
    try store().empty("VALUES (1) FETCH FIRST 0 ROWS ONLY")
    try store().expect("VALUES (1) FETCH FIRST 1 ROWS ONLY", yields: [[1]])
  }

  @Test func `a FROM-less ORDER BY faults on an unresolvable key`() throws {
    // With no source relation an ORDER BY key that is neither an ordinal in
    // range nor an output alias has nothing to bind, so it faults — the same
    // `SQLError.column` the projection raises — and the run and schema derive
    // fault alike.
    try store().expect("VALUES (1) ORDER BY 2", fails: .column("2"))
    try store().expect("VALUES (1) ORDER BY nope", fails: .column("nope"))
  }

  // MARK: - VALUES with a trailing tail (ORDER BY / OFFSET / FETCH)

  @Test func `a standalone multi-row VALUES takes a query-expression tail`()
      throws {
    // A trailing ORDER BY / OFFSET·FETCH after a `VALUES (…), …` binds to the
    // enclosing query expression — the tail rides an output-scoped carrier over
    // the `.values` body, resolving and paging its output rows.
    try store().expect("VALUES (3), (1), (2) ORDER BY 1",
                       yields: [[1], [2], [3]])
    try store().expect("VALUES (3), (1), (2) ORDER BY 1 OFFSET 1 ROWS",
                       yields: [[2], [3]])
  }

  @Test func `a VALUES carrier orders by an output name and a direction`()
      throws {
    // The carrier resolves an `ORDER BY` key against the constructor's default
    // output names (`column1, …`), and honours a per-key `DESC`, exactly as it
    // does over a set operation's output.
    try store().expect("VALUES (3), (1), (2) ORDER BY column1",
                       yields: [[1], [2], [3]])
    try store().expect("VALUES (3), (1), (2) ORDER BY column1 DESC",
                       yields: [[3], [2], [1]])
  }

  @Test func `a VALUES carrier pages with OFFSET and FETCH`() throws {
    // OFFSET and FETCH FIRST n ROWS slice the ordered constructor rows.
    try store().expect(
        "VALUES (3), (1), (2) ORDER BY 1 FETCH FIRST 2 ROWS ONLY",
        yields: [[1], [2]])
    try store().expect("""
        VALUES (5), (4), (3), (2), (1) ORDER BY 1 OFFSET 1 ROWS
        FETCH FIRST 2 ROWS ONLY
        """, yields: [[2], [3]])
    try store().empty("VALUES (1), (2) ORDER BY 1 FETCH FIRST 0 ROWS ONLY")
  }

  @Test func `a multi-column VALUES carrier orders by a later ordinal`()
      throws {
    // A two-column constructor orders on its second output column by ordinal,
    // the carrier resolving the key over the values output slot space.
    try store().expect("VALUES (1, 3), (2, 1), (3, 2) ORDER BY 2",
                       yields: [[2, 1], [3, 2], [1, 3]])
  }

  @Test func `a SELECT DISTINCT over a derived VALUES deduplicates`() throws {
    // DISTINCT collapses the constructor's duplicate rows when a `SELECT
    // DISTINCT` reads them through a derived table, keeping the first of each.
    try store().expect(
        "SELECT DISTINCT column1 FROM (VALUES (1), (1), (2), (1)) AS t "
            + "ORDER BY column1",
        yields: [[1], [2]])
  }

  @Test func `a parenthesized VALUES operand carries its tail before a union`()
      throws {
    // Parenthesised, a VALUES operand takes its own ORDER BY/FETCH before the
    // union: the smallest of {3, 1} is 1, then the second constructor's 9.
    try store().expect("""
        (VALUES (3), (1) ORDER BY 1 FETCH FIRST 1 ROW ONLY)
         UNION ALL VALUES (9)
        """, yields: [[1], [9]])
  }

  @Test func `a VALUES tail composes in a derived table and subquery`()
      throws {
    // A `VALUES` primary with a trailing tail composes as a derived table, a
    // scalar subquery, and an IN-subquery.
    try store().expect(
        "SELECT column1 FROM (VALUES (3), (1), (2) ORDER BY 1) AS t",
        yields: [[1], [2], [3]])
    try store().expect("VALUES ((VALUES (5) ORDER BY 1))", yields: [[5]])
    try roster().expect(
        "SELECT Id FROM People WHERE Id IN (VALUES (3), (1) ORDER BY 1)",
        yields: [[1], [3]])
  }

  // MARK: - EXISTS cardinality probe

  @Test func `an EXISTS VALUES probe evaluates no row cell`() throws {
    // `EXISTS (VALUES …)` reads only the constructor's cardinality, so its cell
    // expressions never evaluate — the probe rewrites each row to a cheap
    // constant, preserving the row count. A would-fault `1 / 0` cell therefore
    // never divides: the one-row constructor is non-empty, so EXISTS holds for
    // every outer row. The schema derive types the row without evaluating it.
    try roster().expect(
        "SELECT Id FROM People WHERE EXISTS (VALUES (1 / 0)) ORDER BY Id",
        yields: [[1], [2], [3], [4], [5]])
    _ = try roster().columns(of:
        parse(query: "SELECT Id FROM People WHERE EXISTS (VALUES (1 / 0))"),
        routines: .standard, validate: true)
  }

  @Test func `a multi-row EXISTS VALUES probe evaluates no cell`() throws {
    // The probe preserves the row count, not the cells: a two-row `VALUES (1 /
    // 0), (2)` probes a two-row constant constructor — EXISTS true, no cell
    // (neither the faulting `1 / 0` nor the `2`) evaluated.
    try roster().expect(
        "SELECT Id FROM People WHERE EXISTS (VALUES (1 / 0), (2)) ORDER BY Id",
        yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a non-EXISTS VALUES still evaluates its cell and faults`()
      throws {
    // The probe rewrite is EXISTS-only, not a general suppression: a `VALUES (1
    // / 0)` reached as a top-level query or as a derived table evaluates its
    // cell as before, so the division still faults.
    try store().expect("VALUES (1 / 0)", fails: .divide)
    try store().expect("SELECT * FROM (VALUES (1 / 0)) AS t", fails: .divide)
  }

  // MARK: - Carrier limit sparing

  @Test func `a VALUES carrier limit spares a discarded row's cell`() throws {
    // A carried `OFFSET`/`FETCH` with no ORDER BY and no DISTINCT applies its
    // positional page at compile time, slicing the constructor's rows before
    // their cells lower — so a row the page discards never evaluates. A
    // `FETCH FIRST 0 ROWS` keeps none and an `OFFSET` past the sole row keeps
    // none, so the would-fault `1 / 0` never divides and the run is empty, not
    // a fault.
    try store().empty("VALUES (1 / 0) FETCH FIRST 0 ROWS ONLY")
    try store().empty("VALUES (1 / 0) OFFSET 1 ROWS")
    // The `validate: true` derive pages the same discarded rows through the
    // same slice, value-checking only the rows the run evaluates — so it agrees
    // with the run and does not fault the discarded `1 / 0`. Its reachability
    // now matches a `FETCH FIRST 0 ROWS` SELECT, whose projection is unreachable
    // (and non-faulting) under a page that keeps no row.
    #expect(fault(deriving:
        try parse(query: "VALUES (1 / 0) FETCH FIRST 0 ROWS ONLY")) == nil)
    #expect(fault(deriving:
        try parse(query: "VALUES (1 / 0) OFFSET 1 ROWS")) == nil)
    // The result schema is unaffected: it types the constructor's columns off
    // all the AST rows without building the carrier plan, so a carried
    // constructor still advertises the ISO default `column1` output at its
    // unified type.
    let columns = try store().columns(of:
        parse(query: "VALUES (2), (3) FETCH FIRST 0 ROWS ONLY"),
        routines: .standard, validate: true)
    #expect(columns.map(\.name) == ["column1"])
    #expect(columns.map(\.type) == [.integer])
  }

  @Test func `a VALUES carrier limit still evaluates a surviving row`()
      throws {
    // The sparing is the limit's, not a blanket suppression: a row the page
    // keeps still evaluates its cells. `FETCH FIRST 1 ROW` over `(2), (1 / 0)`
    // keeps the safe row 0 and drops the faulting row 1 — `[2]`, no fault — but
    // over `(1 / 0), (2)` keeps the faulting row 0, so the division faults. An
    // `OFFSET 1` over `(1 / 0), (2)` drops the faulting row 0 and keeps row 1 —
    // `[2]`, no fault.
    try store().expect("VALUES (2), (1 / 0) FETCH FIRST 1 ROW ONLY",
                       yields: [[2]])
    try store().expect("VALUES (1 / 0), (2) FETCH FIRST 1 ROW ONLY",
                       fails: .divide)
    try store().expect("VALUES (1 / 0), (2) OFFSET 1 ROWS", yields: [[2]])
    // The validate derive pages the same rows and agrees row for row: it spares
    // the discarded `1 / 0` and faults the surviving one.
    #expect(fault(deriving:
        try parse(query: "VALUES (2), (1 / 0) FETCH FIRST 1 ROW ONLY")) == nil)
    #expect(fault(deriving:
        try parse(query: "VALUES (1 / 0), (2) FETCH FIRST 1 ROW ONLY"))
        == .divide)
    #expect(fault(deriving:
        try parse(query: "VALUES (1 / 0), (2) OFFSET 1 ROWS")) == nil)
  }

  @Test func `an ORDER BY VALUES carrier evaluates every row before paging`()
      throws {
    // An ORDER BY must materialise and sort every row before the page applies,
    // so the compile-time slice does not engage — the eager `.values` leaf
    // evaluates every cell. `VALUES (1 / 0) ORDER BY 1 FETCH FIRST 0 ROWS` thus
    // still divides and faults, even though the page keeps no row.
    try store().expect("VALUES (1 / 0) ORDER BY 1 FETCH FIRST 0 ROWS ONLY",
                       fails: .divide)
    // The ORDER BY carrier is eager on both paths: the validate derive stops
    // the peel at it and value-checks every row, so it faults the division too.
    #expect(fault(deriving: try parse(query:
        "VALUES (1 / 0) ORDER BY 1 FETCH FIRST 0 ROWS ONLY")) == .divide)
  }

  @Test func `a DISTINCT VALUES carrier evaluates every row before paging`()
      throws {
    // A DISTINCT carrier must evaluate every row to deduplicate it, so the
    // compile-time slice is gated off for it too — the `.values` leaf stays
    // eager under the dedup. A hand-built distinct carrier (the parser emits
    // `distinct: false`, so this is the public-AST path) over `VALUES (1 / 0)`
    // with a `FETCH FIRST 0 ROWS` still faults, proving the sparing is
    // DISTINCT-gated, not a general suppression of cell evaluation.
    let query = Query(body: try parse(query: "VALUES (1 / 0)").body,
                      carriers: [Query.Carrier(distinct: true, order: nil,
                                               limit: Limit(count: 0),
                                               generated: 0)])
    #expect(fault(running: query) == .divide)
  }

  @Test func `a VALUES set operation evaluates every row`() throws {
    // A `UNION` is a set operation, not a carrier, so its arms materialise in
    // full — the compile-time carrier slice never reaches it. `VALUES (1 / 0)
    // UNION VALUES (2)` therefore evaluates the faulting cell and divides,
    // confirming the sparing is limit-carrier-gated.
    try store().expect("VALUES (1 / 0) UNION VALUES (2)", fails: .divide)
  }

  @Test func `a VALUES carrier limit never hides a discarded row's arity`()
      throws {
    // The compile-time slice pages only the value-validation, never the
    // arity/degree derivation — the ISO equal-degree rule holds over all the
    // rows, independent of the page (the result schema is limit-independent,
    // and the run arity-checks every row before its own slice). A `FETCH FIRST
    // 1 ROW` that discards the malformed second row still faults the cross-row
    // arity mismatch — a structural fault, not a value one — on both the run
    // and the validate path, exactly as it does with no carrier.
    try store().expect("VALUES (1), (2, 3) FETCH FIRST 1 ROW ONLY",
                       fails: .arity(1, 2))
    #expect(fault(deriving:
        try parse(query: "VALUES (1), (2, 3) FETCH FIRST 1 ROW ONLY"))
        == .arity(1, 2))
  }

  @Test func `a VALUES carrier limit trims a generated column`() throws {
    // A public `Query.Carrier` may combine a nonzero `generated` with a limit
    // over a wider `.values` — the parser only ever emits `generated: 0`, so
    // this is the hand-built-AST path. The carrier's compile-time row slice
    // pages the rows positionally, but must still trim the trailing `generated`
    // hidden columns, exactly as the schema path does (`columns(unifying:)`
    // drops them through `cols.prefix(real)`): the slice returns the `.values`
    // leaf directly, so without the trim the run yields all `width` columns
    // where `columns(of:)` advertises `width − generated` — a run ≠ schema
    // split. Over a two-column `VALUES` with `generated: 1` and a `FETCH FIRST
    // 1 ROW` limit, both the derive and the run resolve to one column.
    let carrier = Query.Carrier(distinct: false, order: nil,
                                limit: Limit(count: 1), generated: 1)
    let query = Query(body: try parse(query: "VALUES (1, 2), (3, 4)").body,
                      carriers: [carrier])
    let columns = try store().columns(of: query, routines: .standard,
                                      validate: true)
    #expect(columns.count == 1)
    let rows = try store().run(query, .standard)
    // The limit keeps the first row and the trim drops its second column, so
    // the run yields the single leading cell — the same one-column arity the
    // derive advertises.
    #expect(rows == [[.integer(1)]])
    #expect(rows.first?.count == columns.count)

    // The trim rides above the positional slice, not instead of it: the limit
    // still spares a discarded row's cell. `FETCH FIRST 1 ROW` keeps only the
    // first row, so a would-fault `1 / 0` in the dropped second row never
    // evaluates — the run does not fault and yields the surviving leading cell.
    let spared = Query(body: try parse(query: "VALUES (1, 2), (1 / 0, 4)").body,
                       carriers: [carrier])
    #expect(fault(running: spared) == nil)
    #expect(try store().run(spared, .standard) == [[.integer(1)]])
  }

  // MARK: - Malformed hand-built nodes

  @Test func `an empty VALUES node faults on run and validate`() throws {
    // `Query`/`Query.Body` are public, so a caller can hand-build a `VALUES`
    // with no rows — a shape the parser (≥ 1 row) never emits. The single
    // deriver both the run and `columns(of: validate:)` reach rejects it with a
    // typed `42601`, rather than silently deriving an empty relation.
    let empty = Query(body: .values([]))
    #expect(fault(running: empty)?.sqlstate == "42601")
    #expect(fault(deriving: empty)?.sqlstate == "42601")
  }

  @Test func `a zero-column VALUES row faults on run and validate`() throws {
    // A single zero-column row (`VALUES ()`, which the parser also rejects) is
    // faulted alike — a query yielding a zero-column relation is not a valid
    // shape — on both the run and the validate path.
    let bare = Query(body: .values([[]]))
    #expect(fault(running: bare)?.sqlstate == "42601")
    #expect(fault(deriving: bare)?.sqlstate == "42601")
  }

  @Test func `a well-formed hand-built VALUES node runs`() throws {
    // A hand-built node with rows and columns is unaffected by the guard.
    let node = Query(body: .values([[.literal(.integer(1))],
                                    [.literal(.integer(2))]]))
    let rows = try store().run(node, .standard)
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }
}
