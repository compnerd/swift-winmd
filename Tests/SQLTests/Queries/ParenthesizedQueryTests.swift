// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Parenthesized query expressions (ISO <query primary>)

/// Three integer relations for set-operation composition — A {1, 2}, B {2, 3},
/// C {3, 4}, so each pairing's union/intersect/difference is legible.
private func sets() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["n": .integer]) { Row(1); Row(2) }
    Relation("B", ["n": .integer]) { Row(2); Row(3) }
    Relation("C", ["n": .integer]) { Row(3); Row(4) }
  }
}

struct ParenthesizedQueryTests {
  @Test func `a parenthesized operand overrides set-operation precedence`()
      throws {
    // Without parentheses INTERSECT binds tighter, so `A UNION B INTERSECT C`
    // is `A UNION (B INTERSECT C)`. Parenthesising the union forces it first:
    // `(A UNION B) INTERSECT C` is {1, 2, 3} intersected with {3, 4} = {3}.
    try sets().expect("""
        (SELECT n FROM A UNION SELECT n FROM B)
         INTERSECT SELECT n FROM C
        """, yields: [[3]])
  }

  @Test func `the default precedence is unchanged without parentheses`()
      throws {
    // `A UNION B INTERSECT C` is `A UNION (B INTERSECT C)` = {1, 2} ∪ {3}.
    try sets().expect("""
        SELECT n FROM A UNION SELECT n FROM B INTERSECT SELECT n FROM C
        """, yields: [[1], [2], [3]])
  }

  @Test func `a parenthesized operand carries its own ORDER BY and FETCH`()
      throws {
    // The parentheses let one operand take its top row before the union: the
    // highest n of A is 2, unioned with B {2, 3} gives {2, 3}. The per-operand
    // ORDER BY/FETCH rides a nested `ordered` carrier the outer union composes.
    try sets().expect("""
        (SELECT n FROM A ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
         UNION SELECT n FROM B
        """, yields: [[2], [3]])
  }

  @Test func `a parenthesized query nests on either side of a set operation`()
      throws {
    // A right-hand parenthesised union, and doubled parentheses, both compose:
    // A ∪ (B ∪ C) = {1, 2, 3, 4}.
    try sets().expect("""
        SELECT n FROM A UNION (SELECT n FROM B UNION SELECT n FROM C)
        """, yields: [[1], [2], [3], [4]])
    try sets().expect("""
        ((SELECT n FROM A)) UNION (SELECT n FROM C)
        """, yields: [[1], [2], [3], [4]])
  }

  @Test func `a trailing ORDER BY applies to a parenthesized whole`() throws {
    // A parenthesised set operation followed by a query-level ORDER BY sorts the
    // combined result: (A ∪ C) descending = 4, 3, 2, 1.
    try sets().expect("""
        (SELECT n FROM A UNION SELECT n FROM C) ORDER BY n DESC
        """, yields: [[4], [3], [2], [1]])
  }

  @Test func `run and schema agree on a parenthesized query`() throws {
    // The nested `setop`/`ordered` a parenthesised operand builds derives the
    // same single integer column the run yields.
    let cat = try sets()
    let sql = "(SELECT n FROM A UNION SELECT n FROM B) INTERSECT SELECT n FROM C"
    let columns = try cat.columns(of: parse(query: sql), validate: true)
    #expect(columns == [OutputColumn(name: "n", type: .integer)])
  }

  @Test func `an empty parenthesized query is a syntax fault`() throws {
    // `()` has no query expression inside, so it faults at parse rather than
    // producing an empty primary.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "() UNION SELECT n FROM A")
    }
  }

  @Test func `a right-hand parenthesized operand's FETCH limits only itself`()
      throws {
    // The parentheses seal the operand's ORDER BY/FETCH so the enclosing
    // `query()`'s trailing-tail lift cannot hoist them over the whole union:
    // `A UNION ALL (SELECT … ORDER BY … FETCH 1)` fetches the top row of B (3),
    // not the top row of the combined union. Without the boundary the FETCH
    // would apply to the union and return a single row.
    try sets().expect("""
        SELECT n FROM A
         UNION ALL (SELECT n FROM B ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
        """, yields: [[1], [2], [3]])
  }

  @Test func `a parenthesized operand orders by a non-projected column`()
      throws {
    // The parenthesised operand compiles under its OWN full scope — as a derived
    // table does — so its ORDER BY may reference a column it does not project. Ordering
    // B by the unselected `m` and fetching one row takes the row with the largest
    // m (n = 3), unioned with A.
    let cat = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("B", ["n": .integer, "m": .integer]) { Row(2, 20); Row(3, 30) }
    }
    try cat.expect("""
        SELECT n FROM A
         UNION ALL (SELECT n FROM B ORDER BY m DESC FETCH NEXT 1 ROWS ONLY)
        """, yields: [[1], [3]])
  }

  @Test func `both operands carry independent ORDER BY and FETCH`() throws {
    // Each parenthesised operand takes its own top row before the union: A's
    // highest is 2, B's highest is 3.
    try sets().expect("""
        (SELECT n FROM A ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
         UNION ALL (SELECT n FROM B ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
        """, yields: [[2], [3]])
  }

  @Test func `a parenthesized operand materializes its derived tables`() throws {
    // A parenthesised ordered/limited select reading a derived table `d` must
    // still materialize it — the operand carries its tail on its own select (no
    // marker node), so it is a plain query the derived-table augmentation sees.
    // Both as a whole query and as a set-operation operand.
    try sets().expect("""
        (SELECT n FROM (SELECT n FROM B) AS d
          ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
        """, yields: [[3]])
    try sets().expect("""
        SELECT n FROM A
         UNION ALL (SELECT n FROM (SELECT n FROM B) AS d
                     ORDER BY n DESC FETCH NEXT 1 ROWS ONLY)
        """, yields: [[1], [2], [3]])
  }

  @Test func `a parenthesized grouping-sets select materializes a derived table`()
      throws {
    // A parenthesised GROUPING SETS select over a derived table: the expansion
    // wraps the arms in one carrier (no marker nests a second around it), so the
    // carrier descent reaches the arms and each augments and materializes `d`.
    try sets().expect("""
        (SELECT n FROM (SELECT n FROM B) AS d
          GROUP BY GROUPING SETS ((n), ())) ORDER BY n
        """, yields: [[nil], [2], [3]])
  }

  @Test func `a trailing ORDER BY follows a simple parenthesized query`()
      throws {
    // A query-level `ORDER BY`/`FETCH` after a parenthesised simple select —
    // outside the parentheses — is consumed and applied, exactly as it is after
    // a parenthesised set operation. It is output-scoped, ordering the primary's
    // result.
    try sets().expect("(SELECT n FROM A) ORDER BY n DESC", yields: [[2], [1]])
    try sets().expect("""
        (SELECT n FROM A) ORDER BY n DESC FETCH NEXT 1 ROWS ONLY
        """, yields: [[2]])
  }

  @Test func `an outer tail preserves a parenthesized query's derived tables`()
      throws {
    // `(SELECT … FROM (…) AS d) ORDER BY …` wraps the inner select in an
    // `ordered` carrier after the `)`. That carrier must stay transparent to
    // select-scoped derived-table augmentation (`collect(derived:)`), or `d`
    // goes unmaterialised and the run faults `.scan("d")`. Ordering the derived
    // `d` = B {2, 3}. Run and schema agree.
    try sets().expect("(SELECT n FROM (SELECT n FROM B) AS d) ORDER BY n",
                      yields: [[2], [3]])
    let cat = try sets()
    #expect(throws: Never.self) {
      _ = try cat.columns(of:
          parse(query: "(SELECT n FROM (SELECT n FROM B) AS d) ORDER BY n"))
    }
  }

  @Test func `EXISTS through an outer OFFSET keeps inner DISTINCT cardinality`()
      throws {
    // A carrier OFFSET over a DISTINCT inner: the probe must NOT collapse the
    // inner projection to a constant — that would leave one distinct row the
    // OFFSET then drops — because the OFFSET depends on the distinct-row count.
    // Two distinct Flags, OFFSET 1 → one row remains → EXISTS true.
    let two = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("S", ["Flag": .integer]) { Row(1); Row(1); Row(2) }
    }
    try two.expect("""
        SELECT n FROM A
         WHERE EXISTS ((SELECT DISTINCT Flag FROM S) OFFSET 1 ROWS)
        """, yields: [[1]])
    // One distinct value: OFFSET 1 drops it → EXISTS false → no rows.
    let one = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("S", ["Flag": .integer]) { Row(7); Row(7) }
    }
    try one.expect("""
        SELECT n FROM A
         WHERE EXISTS ((SELECT DISTINCT Flag FROM S) OFFSET 1 ROWS)
        """, yields: [])
  }

  @Test func `EXISTS through a stacked carrier keeps inner DISTINCT cardinality`()
      throws {
    // A DISTINCT select under an ORDER BY carrier, then an outer OFFSET carrier
    // — `((SELECT DISTINCT …) ORDER BY …) OFFSET 1` — stacks two `ordered`
    // nodes between the probe and the DISTINCT. The probe's dedup check must be
    // carrier-transparent (peel the whole stack), or it collapses the result to
    // one row and the offset drops it. Two distinct Flags, OFFSET 1 → one row
    // remains → EXISTS true.
    let cat = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("S", ["Flag": .integer]) { Row(1); Row(1); Row(2) }
    }
    try cat.expect("""
        SELECT n FROM A
         WHERE EXISTS (((SELECT DISTINCT Flag FROM S) ORDER BY Flag) OFFSET 1 ROWS)
        """, yields: [[1]])
  }

  @Test func `an outer tail on a parenthesized simple query is output-scoped`()
      throws {
    // A parenthesised simple query is an ISO `<query primary>`: an ORDER BY
    // after the `)` binds against its OUTPUT columns, not the FROM scope closed
    // inside the parentheses. Ordering by the projected `n` works; ordering by
    // the unprojected `m` faults `.column`, exactly as a set operation's outer
    // tail does — the parenthesis boundary is preserved. Run and schema agree.
    let cat = try Catalog {
      Relation("B", ["n": .integer, "m": .integer]) { Row(2, 20); Row(3, 10) }
    }
    try cat.expect("(SELECT n FROM B) ORDER BY n DESC", yields: [[3], [2]])
    cat.expect("(SELECT n FROM B) ORDER BY m DESC", fails: .column("m"))
    #expect(throws: SQLError.column("m")) {
      _ = try cat.columns(of: parse(query: "(SELECT n FROM B) ORDER BY m"),
                          validate: true)
    }
    // The SAME key written INSIDE the parentheses is the operand's own,
    // full-scoped order over a simple select, so `m` resolves and orders it —
    // the extended-sort-key allowance, unchanged.
    try cat.expect("(SELECT n FROM B ORDER BY m DESC)", yields: [[2], [3]])
  }

  @Test func `EXISTS over a parenthesized select probes existence only`()
      throws {
    // EXISTS inspects only whether rows exist; a parenthesised select is a plain
    // select the cardinality probe replaces, so the run never evaluates the
    // select list. `1 / (Flag - 1)` divides by zero for the Flag = 1 row, yet
    // EXISTS returns true (S is non-empty) without faulting — even with a FETCH
    // suffix, which stays on the select as a cardinality-affecting limit the
    // probe keeps. Run and schema agree.
    let cat = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("S", ["Flag": .integer]) { Row(1); Row(2) }
    }
    try cat.expect("""
        SELECT n FROM A WHERE EXISTS ((SELECT 1 / (Flag - 1) FROM S))
        """, yields: [[1]])
    try cat.expect("""
        SELECT n FROM A
         WHERE EXISTS ((SELECT 1 / (Flag - 1) FROM S) FETCH NEXT 1 ROWS ONLY)
        """, yields: [[1]])
  }

  @Test func `a parenthesized aggregate-ordered operand unions at its real width`()
      throws {
    // A parenthesised operand ordering by an UNPROJECTED aggregate materialises
    // a hidden sort column its carrier trims. The set-operation arity check must
    // count the operand's real (trimmed) width, so this one-column union is not
    // rejected as one-versus-two.
    let cat = try Catalog {
      Relation("A", ["n": .integer]) { Row(1) }
      Relation("D", ["n": .integer, "m": .integer]) { Row(1, 10); Row(2, 20) }
    }
    try cat.expect("""
        SELECT n FROM A
         UNION (SELECT n FROM D GROUP BY GROUPING SETS ((n), ())
                 ORDER BY SUM(m) DESC)
         ORDER BY n
        """, yields: [[nil], [1], [2]])
  }

  @Test func `an outer tail rides a parenthesized primary that has its own tail`()
      throws {
    // A parenthesised primary that carries an inner ORDER BY/FETCH is a `<query
    // primary>`; an outer tail after the `)` is the enclosing query
    // expression's, independently scoped — the inner picks the operand's rows,
    // the outer orders that primary's result. Both bind (a second carrier),
    // never a `42601` duplicate-clause error. Here the inner takes A's top row
    // (n = 2), and the outer ORDER BY of that single row is a no-op.
    try sets().expect("""
        (SELECT n FROM A ORDER BY n DESC FETCH FIRST 1 ROW ONLY) ORDER BY n ASC
        """, yields: [[2]])
    // Nested over a set operation: the inner union takes its top row, the outer
    // re-orders it. (A ∪ C) = {1,2,3,4}, inner top-1 by n DESC = 4; outer ASC of
    // that one row.
    try sets().expect("""
        (SELECT n FROM A UNION SELECT n FROM C ORDER BY n DESC FETCH FIRST 1 ROW
         ONLY) ORDER BY n ASC
        """, yields: [[4]])
  }

  @Test func `a doubly-parenthesized query nests as a derived table`() throws {
    // The derived-table lookahead admits a leading `(` (a nested query primary),
    // so `FROM ((SELECT …)) AS d` parses and runs as `FROM (SELECT …) AS d`
    // rather than faulting at the relation lookahead.
    try sets().expect("SELECT n FROM ((SELECT n FROM A)) AS d",
                      equals: "SELECT n FROM (SELECT n FROM A) AS d")
    try sets().expect("SELECT n FROM ((SELECT n FROM A)) AS d",
                      yields: [[1], [2]])
  }

  @Test func `a doubly-parenthesized IN subquery is membership not a value list`()
      throws {
    // `IN ((SELECT …))` is a table subquery over the parenthesised query primary
    // — membership — not a one-element value list holding a scalar subquery, so
    // a multi-row inner performs membership rather than raising a cardinality
    // error. B = {2, 3}; A's 2 is a member.
    try sets().expect("SELECT n FROM A WHERE n IN ((SELECT n FROM B))",
                      yields: [[2]])
    // A comma list stays a value list — the speculative parse rewinds on the
    // comma. Parenthesised scalars, and a list of single-row subqueries, both
    // remain value lists.
    try sets().expect("SELECT n FROM A WHERE n IN ((1), (2))",
                      yields: [[1], [2]])
    try sets().expect("""
        SELECT n FROM A
         WHERE n IN ((SELECT n FROM B WHERE n = 2), (SELECT n FROM C WHERE n = 4))
        """, yields: [[2]])
  }

  @Test func `a parenthesized scalar subquery body is a query`() throws {
    // A scalar subquery whose body starts with `(` — `((SELECT …) UNION …)` —
    // is a subquery over the union, not a parenthesised expression that fails at
    // UNION. It yields the union's single value. A parenthesised scalar
    // expression starting with `(` still parses as an expression (the
    // speculative query parse rewinds on the trailing operator).
    try sets().expect("SELECT ((SELECT 1) UNION SELECT 1)", yields: [[1]])
    try sets().expect("VALUES (((1) + 2))", yields: [[3]])
  }

  @Test func `an unterminated parenthesized query faults`() throws {
    // A missing `)` after the inner query is a syntax fault.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "(SELECT n FROM A UNION SELECT n FROM B")
    }
  }
}
