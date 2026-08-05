// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A small join catalog: a `Child` keyed on `Pid`, a `Parent` and `People` each
/// sorted on `Id` (so an equi-join on them seeks), and an `Unsorted` whose join
/// key is not sorted (so the executor would hash it — a plan the optimiser
/// still shapes as the same index-nested-loop `join` node).
private func fixtures() throws -> FixtureCatalog {
  try Catalog {
    Relation("Child", ["Pid": .integer, "Kid": .text], sorted: "Pid") {
      Row(1, "Ann")
      Row(2, "Bob")
    }
    Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
      Row(1, "Ada")
      Row(2, "Bee")
    }
    Relation("Unsorted", ["Id": .integer, "Tag": .text]) {
      Row(1, "x")
      Row(2, "y")
    }
    Relation("People", ["Id": .integer, "Name": .text, "Age": .integer],
             sorted: "Id") {
      Row(1, "Alice", 30)
      Row(2, "Bob", 40)
    }
  }
}

/// The rendered plan-tree lines of `sql` planned against `catalog` — the exact
/// output `EXPLAIN <sql>` yields, built through the shared compile → pushdown →
/// decorrelate → optimise pipeline without executing.
private func lines(_ catalog: borrowing FixtureCatalog, _ sql: String,
                   _ bindings: Bindings = [:]) throws -> Array<String> {
  let query = try parse(query: sql)
  let context = Context(routines: .standard, bindings: bindings)
  return try catalog.render(catalog.plan(of: query, context), context)
}

// MARK: - Leaf and seek

@Suite struct ExplainTests {
  @Test func `a sort-key equality plans a seeked scan`() throws {
    let catalog = try fixtures()
    #expect(try lines(catalog, "SELECT Name FROM People WHERE Id = 2") == [
      "project [slot 1]",
      "└─ scan People  reads [0, 1]  seek 1..<2  ordered [slot 0 ASC]",
    ])
  }

  @Test func `a range keeps the residual predicate as a select`() throws {
    let catalog = try fixtures()
    // The lower bound seeks; the upper bound stays a residual `select` over the
    // seeked scan.
    #expect(try lines(catalog,
                      "SELECT Name FROM People WHERE Id > 1 AND Id < 9") == [
      "project [slot 1]",
      "└─ select  slot 0 < 9",
      "   └─ scan People  reads [0, 1]  seek 1..<2  ordered [slot 0 ASC]",
    ])
  }

  @Test func `a whole-relation scan plans no seek`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog, "SELECT Name FROM People")
    #expect(rendered.contains { $0.contains("scan People") })
    #expect(rendered.allSatisfy { !$0.contains("seek") })
  }

  // MARK: - Joins

  @Test func `an equi-join plans an index-nested-loop join`() throws {
    let catalog = try fixtures()
    #expect(try lines(catalog,
                      "SELECT Child.Kid, Parent.Name FROM Child "
                    + "JOIN Parent ON Child.Pid = Parent.Id") == [
      "project [slot 1, slot 3]",
      "└─ join (index nested loop)  inner Parent  on slot 0 = slot 2  "
          + "seek column 0  base 2  reads [0, 1]",
      "   └─ scan Child  reads [0, 1]  ordered [slot 0 ASC]",
    ])
  }

  @Test func `a hash-eligible join plans the same node as a seekable one`()
      throws {
    let catalog = try fixtures()
    // Whether the inner join key is sorted (seek) or not (hash) is a runtime
    // choice the executor makes from live seekability; the optimiser shapes
    // both as the one index-nested-loop `join` node, so the physical plan is
    // identical bar the inner relation name — EXPLAIN renders that node
    // faithfully rather than simulating the runtime strategy.
    let hashed = try lines(catalog,
                           "SELECT Child.Kid, Unsorted.Tag FROM Child "
                         + "JOIN Unsorted ON Child.Pid = Unsorted.Id")
    // Byte-for-byte the same node the seekable-inner join plans, bar the inner
    // relation name — the plan does not encode the runtime hash-vs-seek choice.
    #expect(hashed == [
      "project [slot 1, slot 3]",
      "└─ join (index nested loop)  inner Unsorted  on slot 0 = slot 2  "
          + "seek column 0  base 2  reads [0, 1]",
      "   └─ scan Child  reads [0, 1]  ordered [slot 0 ASC]",
    ])
  }

  @Test func `a cross join plans a nested-loop product`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Child.Kid, Parent.Name "
                           + "FROM Child CROSS JOIN Parent")
    #expect(rendered.contains { $0.contains("product (nested loop)") })
    #expect(rendered.allSatisfy { !$0.contains("join") })
  }

  @Test func `a non-equi join stays a product under a select`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Child.Kid, Parent.Name FROM Child "
                           + "JOIN Parent ON Child.Pid < Parent.Id")
    #expect(rendered.contains { $0.contains("select  slot 0 < slot 2") })
    #expect(rendered.contains { $0.contains("product (nested loop)") })
  }

  @Test func `a LEFT JOIN plans an outer node`() throws {
    let catalog = try fixtures()
    #expect(try lines(catalog,
                      "SELECT Child.Kid, Parent.Name FROM Child "
                    + "LEFT JOIN Parent ON Child.Pid = Parent.Id") == [
      "project [slot 1, slot 3]",
      "└─ outer LEFT  on slot 0 = slot 2",
      "   ├─ scan Child  reads [0, 1]  ordered [slot 0 ASC]",
      "   └─ scan Parent  reads [0, 1]  ordered [slot 0 ASC]",
    ])
  }

  // MARK: - Sort, distinct, limit, aggregate, window

  @Test func `an ORDER BY plans a sort node`() throws {
    let catalog = try fixtures()
    let rendered =
        try lines(catalog, "SELECT Name FROM People ORDER BY Age DESC")
    #expect(rendered.contains { $0.contains("sort  slot 1 DESC") })
  }

  @Test func `a DISTINCT over a non-unique scan is kept`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog, "SELECT DISTINCT Age FROM People")
    #expect(rendered.contains("distinct"))
  }

  @Test func `a DISTINCT over a grouped unique source is elided`() throws {
    let catalog = try fixtures()
    // The aggregate already yields one row per distinct key, so the optimiser
    // drops the redundant `distinct` — the plan shows the aggregate and no
    // `distinct` node.
    let rendered = try lines(catalog,
                             "SELECT DISTINCT Age FROM People GROUP BY Age")
    #expect(!rendered.contains("distinct"))
    #expect(rendered.contains { $0.contains("aggregate") })
  }

  @Test func `an OFFSET·FETCH plans a limit node`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Name FROM People "
                           + "OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY")
    #expect(rendered.contains { $0.contains("limit  count 2  offset 1") })
  }

  @Test func `a bounded ORDER BY OFFSET FETCH fuses into a top-N node`()
      throws {
    let catalog = try fixtures()
    // A `.limit` directly over a `.sort` with a bounded FETCH fuses into a
    // single `top-N` node — the full sort and the cap collapse into one bounded
    // selection. The node renders its cap, offset, and keys.
    #expect(try lines(catalog,
                      "SELECT Name FROM People ORDER BY Age DESC "
                    + "OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY") == [
      "project [slot 0]",
      "└─ top-N  count 2  offset 1  by slot 1 DESC",
      "   └─ scan People  reads [1, 2]",
    ])
  }

  @Test func `an unbounded OFFSET is not fused into a top-N node`() throws {
    let catalog = try fixtures()
    // An `OFFSET` with no `FETCH` is unbounded — there is nothing to bound — so
    // the fusion never fires: the plan keeps the full sort under a limit.
    let rendered =
        try lines(catalog, "SELECT Name FROM People ORDER BY Age OFFSET 1 ROWS")
    #expect(rendered.allSatisfy { !$0.contains("top-N") })
    #expect(rendered.contains { $0.contains("sort  slot 1 ASC") })
    #expect(rendered.contains { $0.contains("limit  count all  offset 1") })
  }

  @Test func `a DISTINCT ORDER BY FETCH is not fused into a top-N node`()
      throws {
    let catalog = try fixtures()
    // The cap sits over the `.distinct` (which sits over the `.sort`), not
    // directly over the sort, so the fusion pattern never matches it — dedup
    // stays before the cap and no `top-N` forms.
    let rendered = try lines(catalog,
                             "SELECT DISTINCT Age FROM People ORDER BY Age "
                           + "FETCH FIRST 2 ROWS ONLY")
    #expect(rendered.allSatisfy { !$0.contains("top-N") })
    #expect(rendered.contains { $0.contains("limit  count 2") })
    #expect(rendered.contains { $0.contains("distinct") })
  }

  @Test func `a GROUP BY plans an aggregate with its keys and folds`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Age, COUNT(*) FROM People GROUP BY Age")
    #expect(rendered.contains {
      $0.contains("aggregate  keys [slot 0]  aggregates [COUNT(*)]")
    })
  }

  @Test func `a window function plans a window node with its OVER clause`()
      throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Name, ROW_NUMBER() OVER "
                           + "(PARTITION BY Age ORDER BY Id) FROM People")
    #expect(rendered.contains {
      $0.contains("window [ROW_NUMBER() OVER "
                + "(PARTITION BY slot 2 ORDER BY slot 0 ASC)]")
    })
  }

  @Test func `an explicit window frame is rendered in the OVER clause`()
      throws {
    let catalog = try fixtures()
    // The frame's unit and bounds are rendered, so a window is distinct from
    // one folding a different row set.
    let one = try lines(catalog, "SELECT SUM(Age) OVER (ORDER BY Id "
                              + "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) "
                              + "FROM People")
    #expect(one.contains {
      $0.contains("ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")
    })
    // A wider frame folds different rows, so it must plan differently.
    let five = try lines(catalog, "SELECT SUM(Age) OVER (ORDER BY Id "
                               + "ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) "
                               + "FROM People")
    #expect(one != five)
  }

  @Test func `a LEAD default operand is rendered`() throws {
    let catalog = try fixtures()
    // The third operand — the partition-edge default — is part of the value,
    // so it is rendered; `LEAD(A, 1, 0)` must not read like the implicit-NULL
    // form.
    let withDefault =
        try lines(catalog, "SELECT LEAD(Age, 1, 0) OVER (ORDER BY Id) "
                         + "FROM People")
    #expect(withDefault.contains { $0.contains(", 1, 0)") })
    let without =
        try lines(catalog, "SELECT LEAD(Age, 1) OVER (ORDER BY Id) FROM People")
    #expect(withDefault != without)
  }

  // MARK: - Decorrelation

  @Test func `a correlated EXISTS decorrelates to a semijoin`() throws {
    let catalog = try fixtures()
    #expect(try lines(catalog,
                      "SELECT Name FROM Parent WHERE EXISTS "
                    + "(SELECT 1 FROM Child WHERE Child.Pid = Parent.Id)") == [
      "project [slot 1]",
      "└─ semijoin  on slot 0 = slot 2",
      "   ├─ scan Parent  reads [0, 1]  ordered [slot 0 ASC]",
      "   └─ scan Child  reads [0]  ordered [slot 0 ASC]",
    ])
  }

  @Test func `a correlated NOT EXISTS decorrelates to an anti-semijoin`()
      throws {
    let catalog = try fixtures()
    let sql = "SELECT Name FROM Parent WHERE NOT EXISTS "
            + "(SELECT 1 FROM Child WHERE Child.Pid = Parent.Id)"
    let rendered = try lines(catalog, sql)
    #expect(rendered.contains { $0.contains("semijoin (anti)") })
  }

  @Test func `a decorrelatable LATERAL folds to a join`() throws {
    let catalog = try fixtures()
    // The correlated CROSS APPLY decorrelates into a set-based equi-join —
    // there is no `apply` node left in the plan.
    let rendered = try lines(catalog,
                             "SELECT Parent.Name, d.Kid FROM Parent "
                           + "CROSS JOIN LATERAL (SELECT Kid FROM Child "
                           + "WHERE Child.Pid = Parent.Id) AS d")
    #expect(rendered.contains { $0.contains("join (index nested loop)") })
    #expect(rendered.allSatisfy { !$0.contains("apply") })
  }

  @Test func `a non-decorrelatable LATERAL stays an apply with correlation`()
      throws {
    let catalog = try fixtures()
    // A lateral whose body aggregates does not decorrelate, so it stays an
    // `apply` — its correlation (the outer cell each re-execution binds) shown.
    let rendered = try lines(catalog,
                             "SELECT Parent.Name, d.n FROM Parent "
                           + "CROSS JOIN LATERAL (SELECT COUNT(*) AS n FROM "
                           + "Child WHERE Child.Pid = Parent.Id) AS d")
    #expect(rendered.contains {
      $0.contains("apply INNER  correlation [:__correlated_0_0 ← slot 0]")
    })
  }

  // MARK: - Subqueries and set operations

  @Test func `a scalar subquery renders in the projection`() throws {
    let catalog = try fixtures()
    let rendered = try lines(catalog,
                             "SELECT Name, (SELECT COUNT(*) FROM Child) "
                           + "FROM Parent")
    #expect(rendered.contains { $0.contains("(subquery)") })
  }

  @Test func `a UNION plans a setop over its two arms`() throws {
    let catalog = try fixtures()
    #expect(try lines(catalog,
                      "SELECT Id FROM People UNION SELECT Id FROM Parent") == [
      "union",
      "├─ project [slot 0]",
      "│  └─ scan People  reads [0]  ordered [slot 0 ASC]",
      "└─ project [slot 0]",
      "   └─ scan Parent  reads [0]  ordered [slot 0 ASC]",
    ])
  }

  // MARK: - SQL surface

  @Test func `EXPLAIN parses to an explain statement`() throws {
    let statement = try Statement(parsing: "EXPLAIN SELECT Name FROM People")
    guard case .explain = statement else {
      Issue.record("expected an .explain statement")
      return
    }
  }

  @Test func `EXPLAIN at statement start is contextual and case-insensitive`()
      throws {
    let catalog = try fixtures()
    // Recognised in any case at statement start; a set-operation query is a
    // valid inspected query too.
    for keyword in ["EXPLAIN", "explain", "Explain"] {
      let statement =
          try Statement(parsing: "\(keyword) SELECT Name FROM People")
      guard case .explain = statement else {
        Issue.record("expected an .explain statement for \(keyword)")
        return
      }
      #expect(try !catalog.run(statement, .standard).isEmpty)
    }
  }

  @Test func `Explain is an ordinary identifier away from statement start`()
      throws {
    // `EXPLAIN` is not reserved, so a relation, column, and alias all named
    // `Explain` — the exact names the reserved token used to break — parse and
    // run as ordinary identifiers.
    let catalog = try Catalog {
      Relation("Explain", ["Explain": .integer]) {
        Row(1)
      }
    }
    try catalog.expect("SELECT * FROM Explain", yields: [[1]])
    try catalog.expect("SELECT Explain FROM Explain", yields: [[1]])
    try catalog.expect("SELECT Explain AS Explain FROM Explain",
                       yields: [[1]])
  }

  @Test func `EXPLAIN yields the plan tree as text rows`() throws {
    let catalog = try fixtures()
    let sql = "SELECT Name FROM People WHERE Id = 2"
    let statement = try Statement(parsing: "EXPLAIN " + sql)
    let rows = try catalog.run(statement, .standard)
    let expected = try lines(catalog, sql).map { [Value.text($0)] }
    #expect(rows == expected)
  }

  @Test func `EXPLAIN describes a single text plan column`() throws {
    let catalog = try fixtures()
    let statement = try Statement(parsing: "EXPLAIN SELECT Name FROM People")
    let columns = try catalog.columns(of: statement, routines: .standard)
    #expect(columns.map(\.name) == ["plan"])
    #expect(columns.map(\.type) == [.text])
  }

  @Test func `describing an unplannable EXPLAIN faults`() throws {
    let catalog = try fixtures()
    // The inspected query names no `Missing` column, so describing the
    // `EXPLAIN` must fault as running it would — a prepare/schema client cannot
    // be handed a plan-column schema for a statement that cannot be planned.
    let statement =
        try Statement(parsing: "EXPLAIN SELECT Missing FROM People")
    #expect(throws: SQLError.self) {
      _ = try catalog.columns(of: statement, routines: .standard,
                              validate: true)
    }
  }

  @Test func `describing an EXPLAIN validates by planning not executing`()
      throws {
    let catalog = try fixtures()
    // `Name + 1` is text + integer — an operand error only a row evaluation
    // raises. Running the EXPLAIN builds a plan and never evaluates it, so
    // describing the EXPLAIN plans without faulting — even though describing
    // the bare SELECT eager-type-checks the operand and does fault.
    let explain =
        try Statement(parsing: "EXPLAIN SELECT Name + 1 FROM People")
    #expect(throws: Never.self) {
      _ = try catalog.columns(of: explain, routines: .standard, validate: true)
    }
    // The EXPLAIN itself runs, so describing it must agree.
    #expect(throws: Never.self) {
      _ = try catalog.run(explain, .standard)
    }
    let select = try Statement(parsing: "SELECT Name + 1 FROM People")
    #expect(throws: SQLError.self) {
      _ = try catalog.columns(of: select, routines: .standard, validate: true)
    }
  }

  @Test func `a text literal with a newline renders on one line`() throws {
    let catalog = try fixtures()
    // The string constant carries a literal newline; the plan literal escapes
    // it (`\n`) so the operator stays a single line and the shell's box frame
    // is not corrupted.
    let rendered = try lines(catalog, "SELECT 'a\nb' AS s FROM People")
    #expect(rendered.allSatisfy { !$0.contains("\n") })
    #expect(rendered.contains { $0.contains("'a\\nb'") })
  }

  @Test func `a text literal with a quote renders it escaped`() throws {
    let catalog = try fixtures()
    // A doubled `''` embeds one quote (ISO); the plan literal escapes it (`\'`)
    // so the quoting is unambiguous rather than reading as a closed string.
    let rendered = try lines(catalog, "SELECT 'it''s' AS s FROM People")
    #expect(rendered.contains { $0.contains("'it\\'s'") })
  }

  @Test func `a delimited relation name with a newline renders on one line`()
      throws {
    // A delimited identifier is verbatim and may hold a newline; the scan label
    // escapes it (`\n`) so the operator stays a single line rather than
    // splitting the row and corrupting the shell's box frame.
    let catalog = try Catalog {
      Relation("a\nb", ["x": .integer]) { Row(1) }
    }
    let query = try parse(query: "SELECT x FROM \"a\nb\"")
    let context = Context(routines: .standard)
    let rendered = try catalog.render(catalog.plan(of: query, context),
                                      context)
    #expect(rendered.allSatisfy { !$0.contains("\n") })
    #expect(rendered.contains { $0.contains("scan a\\nb") })
  }

  @Test func `the EXPLAIN feature leaves a normal query's rows unchanged`()
      throws {
    let catalog = try fixtures()
    // A plain SELECT still returns its own rows — EXPLAIN is purely diagnostic
    // and never touches the execution path of a non-EXPLAIN query.
    try catalog.expect("SELECT Name FROM People WHERE Id = 2",
                       yields: [["Bob"]])
  }
}

// MARK: - Plan-only augmentation

private final class Counter: @unchecked Sendable {
  private(set) var count = 0
  func next() -> Int { count += 1; return count }
}

/// `EXPLAIN` inspects the plan without executing it, so it augments
/// schema-only: a derived table's body never runs — a stateful routine or a
/// throwing derived expression stays unfired — and a bare set operation still
/// resolves each arm's own aliases, as the run path does.
@Suite struct ExplainPlanOnlyTests {
  @Test func `planning a derived table does not run its body`() throws {
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    let catalog = try Catalog {
      Relation("T", ["a": .integer]) { Row(1); Row(2) }
    }
    let query =
        try parse(query: "SELECT x FROM (SELECT tick() AS x FROM T) AS d")
    let context = Context(routines: routines)
    let rendered = try catalog.render(catalog.plan(of: query, context),
                                      context)
    // The plan is produced, and `tick()` never fired — a materialising augment
    // would have run the derived body once per row.
    #expect(!rendered.isEmpty)
    #expect(counter.count == 0)
  }

  @Test func `planning a throwing derived expression does not raise`() throws {
    let catalog = try Catalog {
      Relation("T", ["a": .integer]) { Row(1) }
    }
    // `1 / 0` raises at execution; EXPLAIN stops before it, so planning the
    // derived table succeeds rather than surfacing an execution-time fault.
    let query =
        try parse(query: "SELECT x FROM (SELECT 1 / 0 AS x FROM T) AS d")
    let context = Context(routines: .standard)
    #expect(throws: Never.self) {
      _ = try catalog.render(catalog.plan(of: query, context), context)
    }
  }

  @Test func `a bare set operation plans each arm's own aliases`() throws {
    let catalog = try Catalog {
      Relation("T", ["a": .integer]) { Row(1) }
    }
    // Each arm scans an arm-local derived alias (`d`, `e`) the top-level scope
    // does not bind; the plan-only path must optimise each arm under its own
    // augmented scope rather than faulting `.relation`. A carrier-free set
    // operation reaches the plan helper only through `EXPLAIN` — the run path
    // runs its arms directly — so this is the shape a single top-level context
    // would break.
    let sql = "SELECT v FROM (VALUES (1)) AS d(v) WHERE v = 1 " +
              "UNION ALL SELECT v FROM (VALUES (2)) AS e(v)"
    let query = try parse(query: sql)
    let context = Context(routines: .standard)
    #expect(throws: Never.self) {
      _ = try catalog.render(catalog.plan(of: query, context), context)
    }
  }

  @Test func `a bare set operation decorrelates an arm under its own scope`()
      throws {
    let catalog = try Catalog {
      Relation("Child", ["Pid": .integer]) {
        Row(1)
        Row(2)
      }
    }
    // The first arm's correlated EXISTS names the arm-local `d.v`, which the
    // shared top-level scope does not bind — so a shared-context decorrelation
    // bails and leaves it correlated. Running the bare UNION decorrelates each
    // arm under its own augmented scope to a semijoin; the inspected plan must
    // match, not report the correlated form the run never uses.
    let sql = "SELECT v FROM (VALUES (1)) AS d(v) " +
              "WHERE EXISTS (SELECT 1 FROM Child WHERE Child.Pid = v) " +
              "UNION ALL SELECT Pid FROM Child"
    let query = try parse(query: sql)
    let context = Context(routines: .standard)
    let rendered = try catalog.render(catalog.plan(of: query, context),
                                      context)
    #expect(rendered.contains { $0.contains("semijoin") })
  }
}

// MARK: - Convergence guards

/// Structural guards that catch a whole class of EXPLAIN regressions at once,
/// rather than one query at a time: the renderer must distinguish physically
/// different plans (a dropped field collapses two), and describing an EXPLAIN
/// must agree with planning it (the diagnostic must not diverge from the run).
@Suite struct ExplainConvergenceTests {
  /// Each query below is physically distinct from every other — a different
  /// source, filter, seek, sort, limit, window frame, offset default, or set
  /// operation. If the renderer drops a distinguishing field (as it once
  /// dropped the window frame and the LEAD default), two of these collapse to
  /// the same text and the count no longer matches. This catches a dropped
  /// field without a per-field golden.
  @Test func `physically distinct queries render distinctly`() throws {
    let catalog = try fixtures()
    let queries = [
      "SELECT Age FROM People",
      "SELECT Name FROM People",
      "SELECT Age FROM People WHERE Id = 1",
      "SELECT Age FROM People WHERE Id = 2",
      "SELECT Age, Name FROM People",
      "SELECT Age FROM People WHERE Age > 1",
      "SELECT Age FROM People ORDER BY Age",
      "SELECT Age FROM People ORDER BY Age DESC",
      "SELECT Name FROM People ORDER BY Id",
      "SELECT Name FROM People ORDER BY Id DESC",
      "SELECT DISTINCT Age FROM People",
      "SELECT Age FROM People OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY",
      "SELECT Age FROM People OFFSET 2 ROWS FETCH FIRST 2 ROWS ONLY",
      "SELECT Age FROM People OFFSET 1 ROWS FETCH FIRST 3 ROWS ONLY",
      "SELECT Age FROM People ORDER BY Age FETCH FIRST 1 ROWS ONLY",
      "SELECT Age FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY",
      "SELECT Age FROM People ORDER BY Age DESC FETCH FIRST 2 ROWS ONLY",
      "SELECT Age FROM People ORDER BY Age "
        + "OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY",
      "SELECT SUM(Age) OVER (ORDER BY Id "
        + "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM People",
      "SELECT SUM(Age) OVER (ORDER BY Id "
        + "ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) FROM People",
      "SELECT SUM(Age) OVER (ORDER BY Id "
        + "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM People",
      "SELECT SUM(Age) OVER (ORDER BY Id "
        + "RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM People",
      "SELECT LEAD(Age, 1) OVER (ORDER BY Id) FROM People",
      "SELECT LEAD(Age, 1, 0) OVER (ORDER BY Id) FROM People",
      "SELECT LEAD(Age, 1, 9) OVER (ORDER BY Id) FROM People",
      "SELECT LEAD(Age, 2, 0) OVER (ORDER BY Id) FROM People",
      "SELECT COUNT(*) FROM People",
      "SELECT COUNT(DISTINCT Age) FROM People",
      "SELECT Age, RANK() OVER (ORDER BY COUNT(*)) "
        + "FROM People GROUP BY Age",
      "SELECT Name FROM Parent WHERE EXISTS "
        + "(SELECT 1 FROM Child WHERE Child.Pid = Parent.Id)",
      "SELECT Name FROM Parent WHERE NOT EXISTS "
        + "(SELECT 1 FROM Child WHERE Child.Pid = Parent.Id)",
      "SELECT Id FROM People UNION SELECT Id FROM Parent",
      "SELECT Id FROM People UNION ALL SELECT Id FROM Parent",
      "SELECT Id FROM People INTERSECT SELECT Id FROM Parent",
    ]
    let renders = try queries.map {
      try lines(catalog, $0).joined(separator: "\n")
    }
    // A collision means two physically different plans render identically.
    #expect(Set(renders).count == queries.count)
  }

  /// Describing an `EXPLAIN` (`columns(of:validate:)`) must succeed on exactly
  /// the queries running the `EXPLAIN` (`run`) succeeds on — both prove the
  /// query plannable, neither evaluates a row. A divergence is the class of bug
  /// that produced the materialise-derived-rows, per-arm-scope, and
  /// validate-by-executing rounds; this asserts agreement across a corpus so a
  /// new divergence fails here rather than in review.
  @Test func `describing an EXPLAIN agrees with planning it`() throws {
    let catalog = try fixtures()
    let queries = [
      "SELECT Age FROM People",
      "SELECT Name + 1 FROM People",
      "SELECT Age FROM People WHERE Id = 2",
      "SELECT COUNT(*) FROM People",
      "SELECT DISTINCT Age FROM People",
      "SELECT Age, RANK() OVER (ORDER BY COUNT(*)) FROM People GROUP BY Age",
      "SELECT Missing FROM People",
      "SELECT Age FROM People WHERE Name = 1",
      "SELECT Id FROM People UNION SELECT Id FROM Parent",
      "SELECT Name FROM Parent WHERE EXISTS "
        + "(SELECT 1 FROM Child WHERE Child.Pid = Parent.Id)",
    ]
    for query in queries {
      let statement = try Statement(parsing: "EXPLAIN " + query)
      let planned = (try? catalog.run(statement, .standard)) != nil
      let described = (try? catalog.columns(of: statement, routines: .standard,
                                            validate: true)) != nil
      #expect(planned == described, "EXPLAIN \(query)")
    }
  }
}

