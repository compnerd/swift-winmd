// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine

// Aggregate and scalar-function term builders — the projection-side vocabulary.
// `count()`, `sum(_:)`, `min(_:)`, `max(_:)`, `avg(_:)` build the engine's
// `Expression.aggregate` node (the engine already supports GROUP BY and these
// aggregates); `call(_:_:)` builds a scalar-function `Expression.call` so a
// projection or predicate can name a registered routine.

extension Term {
  /// `f(arguments)` — a call to the registered scalar function `name` over its
  /// argument terms, each lifted through `TermConvertible`. The function must
  /// resolve in the `Routines` passed to the run — an ISO built-in (`UPPER`,
  /// `SUBSTRING`, …) under `Routines.standard`, or a caller-registered one.
  public static func call(_ name: String,
                          _ arguments: any TermConvertible...) -> Term {
    Term(.call(name: name, arguments: arguments.map(\.term.expression)))
  }
}

/// `COUNT(*)` — the number of rows in the group.
public func count() -> Term {
  Term(.aggregate(.count, of: .star))
}

/// `COUNT(operand)` — the number of non-NULL values of `operand` in the group.
public func count(_ operand: some TermConvertible) -> Term {
  Term(.aggregate(.count, of: .expression(operand.term.expression)))
}

/// `SUM(operand)` — the total of the non-NULL numeric values in the group.
public func sum(_ operand: some TermConvertible) -> Term {
  Term(.aggregate(.sum, of: .expression(operand.term.expression)))
}

/// `MIN(operand)` — the least non-NULL value in the group.
public func min(_ operand: some TermConvertible) -> Term {
  Term(.aggregate(.min, of: .expression(operand.term.expression)))
}

/// `MAX(operand)` — the greatest non-NULL value in the group.
public func max(_ operand: some TermConvertible) -> Term {
  Term(.aggregate(.max, of: .expression(operand.term.expression)))
}

/// `AVG(operand)` — the average of the non-NULL numeric values in the group.
public func avg(_ operand: some TermConvertible) -> Term {
  Term(.aggregate(.avg, of: .expression(operand.term.expression)))
}
