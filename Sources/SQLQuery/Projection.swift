// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine

// The projection vocabulary: a `Projection` item — a term with an optional
// output alias — and the `as(_:)` sugar that names one. `QueryBuilder.select`
// gathers these into the engine's `Projection`, choosing the simpler
// `.columns` case when every item is an unaliased bare column and the richer
// `.expressions` case otherwise (mirroring the parser's own choice).

/// One projected term with an optional output alias — the builder analogue of
/// the engine's `Projected`. A bare `Term` projects unaliased; `term.as("x")`
/// names its output column.
public struct Projection: Hashable, Sendable {
  /// The term this item projects.
  public let term: Term

  /// The output alias, if any.
  public let alias: String?

  public init(_ term: Term, as alias: String? = nil) {
    self.term = term
    self.alias = alias
  }
}

extension Term {
  /// This term projected under the output alias `alias` — `column("x").as("y")`
  /// projects `x AS y`.
  public func `as`(_ alias: String) -> Projection {
    Projection(self, as: alias)
  }
}

extension Projection {
  /// The engine `Projected` this item lowers to.
  internal var projected: Projected {
    Projected(expression: term.expression, alias: alias)
  }

  /// The bare column this item projects unaliased, or `nil` when it aliases or
  /// projects a non-column expression — the test `QueryBuilder.select` uses to
  /// choose the simpler `Projection.columns` lowering.
  internal var column: Column? {
    guard alias == nil, case let .column(column) = term.expression else {
      return nil
    }
    return column
  }
}
