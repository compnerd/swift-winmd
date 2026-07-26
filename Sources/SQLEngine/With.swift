// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - WITH

extension CTE {
  /// The CTE body's canonical recursive shape — the one recogniser every
  /// recursive-CTE seam peels through, so the run side and the schema side
  /// inspect the identical AST.
  ///
  /// It applies `Query.expanded` (a `GROUP BY GROUPING SETS` body lowers to its
  /// `UNION ALL` arms FIRST) then `Query.peeled` (every trailing query-level
  /// `ORDER BY`/`OFFSET`·`FETCH`/`DISTINCT` carrier peels off the setop — a
  /// parenthesised recursive union with its own tail plus an outer tail stacks
  /// two), yielding the carrier-free inner query paired with the peeled
  /// carriers, innermost first. A recursive grouping-sets body thus
  /// canonicalises to the same expanded, peeled shape on both sides. Routing
  /// every seam through this one form keeps the run and schema derivations in
  /// step.
  internal var canonical: (inner: Query, carriers: Array<Query.Carrier>) {
    get throws(SQLError) {
      let (core, carriers) = try query.expanded.peeled
      return (core, carriers)
    }
  }

  /// The CTE body's recursive `UNION` arms — the `(anchor, recursive, all)` of
  /// its `canonical` inner query when that is a `UNION` whose recursive (right)
  /// arm names the CTE — else `nil`. The single recogniser the fixpoint router,
  /// the shape validator, and the schema derive all peel through.
  ///
  /// The parser marks each member of a `WITH RECURSIVE` list recursive whether
  /// or not it names itself, but only a self-referential CTE has a recursive
  /// arm to iterate; running a non-self-referential one through the fixpoint
  /// would re-evaluate an arm that never reads the CTE, repeating its rows
  /// without end (a `UNION ALL`) or needlessly (a `UNION`). A CTE is recursive
  /// in truth when its recursive arm — the right member of the top-level
  /// `UNION`, the one the fixpoint compiles with the CTE bound — names `name`
  /// in a `FROM`/`JOIN`. The anchor is the base case, compiled with the name
  /// NOT in scope, so a `FROM <name>` there reads a base relation of that name,
  /// not the CTE. Scanning the anchor too would misroute `WITH RECURSIVE
  /// Parent(Id) AS (SELECT Id FROM Parent UNION ALL SELECT Id FROM Extra)` —
  /// whose anchor merely reads the same-named base — into the fixpoint.
  internal var recursiveArms:
      (anchor: Query, recursive: Query, all: Bool)? {
    get throws(SQLError) {
      guard case let .setop(.union, anchor, recursive, all) = try canonical
          .inner, recursive.references(name.lowercased()) else {
        return nil
      }
      return (anchor, recursive, all)
    }
  }

  /// Whether the CTE actually references itself through a recursive `UNION` arm
  /// — the test the fixpoint routing turns on, distinct from the syntactic
  /// `recursive` flag a `WITH RECURSIVE` stamps on every member. A thin read
  /// over `recursiveArms`, so it peels the same canonical shape.
  internal var recurses: Bool {
    get throws(SQLError) {
      try recursiveArms != nil
    }
  }
}

extension Query {
  /// Whether the query names the relation `name` (case-folded) in ANY member's
  /// `FROM`/`JOIN` — walking the set-operation tree and each arm. Used to spot
  /// a self-reference lurking in a recursive body's anchor; `CTE.recurses`
  /// itself inspects only the recursive arm.
  internal func references(_ name: String) -> Bool {
    switch self {
    case let .select(select):
      select.references(name)
    case let .setop(_, left, right, _):
      left.references(name) || right.references(name)
    case let .ordered(inner, _, _, _, _):
      inner.references(name)
    }
  }
}

extension Select {
  /// Whether the select names the relation `name` (case-folded) in its `FROM`
  /// or any `JOIN`.
  ///
  /// A relation contributes a reference by its source, not its binding name: a
  /// `.named` relation names `name` when its identifier matches; a `.derived`
  /// one names nothing through its alias — a `FROM (SELECT …) AS a` does not
  /// reference a relation `a` — but its inner query is recursed into for the
  /// REAL `.named` references its body holds. So a recursive-CTE fixpoint
  /// detector sees a self-reference nested inside a derived body (`FROM (SELECT
  /// n FROM a) AS d` names `a`) yet is NOT fooled by a shadowing derived alias
  /// (`FROM (SELECT … ) AS a` does not name the CTE `a`).
  internal func references(_ name: String) -> Bool {
    from?.references(name) ?? false
        || joins.contains { $0.relation.references(name) }
  }
}

extension Relation {
  /// Whether this relation references the relation `name` (case-folded): a
  /// `.named` relation by its identifier, a `.derived` one by recursing into
  /// its inner query — the derived alias itself is not a reference.
  internal func references(_ name: String) -> Bool {
    switch source {
    case let .named(identifier):
      identifier.lowercased() == name
    case let .derived(query):
      query.references(name)
    }
  }
}
