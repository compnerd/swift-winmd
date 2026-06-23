// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The closure query combinators over a typed `TableIterator<Schema>`.
///
/// These mirror the generic `Cursor` combinators (`Filter`/`Projection`), but
/// they walk a statically typed table and hand each stage a borrowed
/// `Row<Schema>` rather than a type-erased `Tuple`, so predicates and
/// projections address columns with leading-dot `Column` tokens —
/// `$0[.TypeName]` — and read the row's typed accessors directly.
///
/// A query is a borrowed traversal: `where` and `select` build lazy
/// `~Escapable` stages that store escapable closures of the form
/// `(borrowing Row<Schema>) -> …`, while the iterator and the transiently
/// materialised `Row` stay on the borrowed side of the escape boundary.
/// Nothing is materialised and nothing allocates per row; stages compose and
/// the scan runs only when a terminal consumes it.
///
/// A projection must yield an escapable value. `.select({ $0 })` does not
/// surface the row — a `Row` cannot escape the closure. To surface rows
/// themselves, hand them to the `(borrowing Row<Schema>) -> Void` callback of
/// `forEach`.

// MARK: - TypedFilter

/// A lazy filtered stage over a `TableIterator<Schema>`.
///
/// It holds the base iterator and a predicate; the predicate is evaluated only
/// when a terminal consumes the stage.
public struct TypedFilter<Schema: TableSchema>: ~Escapable {
  private let base: TableIterator<Schema>
  private let predicate: (borrowing Row<Schema>) -> Bool

  @_lifetime(copy base)
  internal init(_ base: borrowing TableIterator<Schema>,
                _ predicate: @escaping (borrowing Row<Schema>) -> Bool) {
    self.base = copy base
    self.predicate = predicate
  }

  /// Maps each surviving row through `transform`, yielding an escapable value.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Row<Schema>) -> T)
      -> TypedProjection<Schema, T> {
    TypedProjection(base, where: predicate, select: transform)
  }

  // MARK: Terminals

  /// Applies `body` to each surviving row.
  public func forEach(_ body: (borrowing Row<Schema>) -> Void) {
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate(value) {
        body(value)
      }
    }
  }

  /// The first surviving row satisfying `predicate`, passed to `body`.
  ///
  /// Returns the escapable value `body` produces, or `nil` if no row matches.
  public func first<T>(where predicate: (borrowing Row<Schema>) -> Bool,
                       _ body: (borrowing Row<Schema>) -> T) -> T? {
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if self.predicate(value), predicate(value) {
        return body(value)
      }
    }
    return nil
  }

  /// Folds the surviving rows into `initial` with `next`.
  public func reduce<R>(_ initial: R,
                        _ next: (R, borrowing Row<Schema>) -> R) -> R {
    var result = initial
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate(value) {
        result = next(result, value)
      }
    }
    return result
  }

  /// The number of surviving rows.
  public func count() -> Int {
    var count = 0
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate(value) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - TypedProjection

/// A lazy projected stage over a `TableIterator<Schema>`.
///
/// It holds the base iterator, an optional predicate, and a transform mapping a
/// surviving row to an escapable value; both run only when a terminal consumes
/// the stage.
public struct TypedProjection<Schema: TableSchema, T>: ~Escapable {
  private let base: TableIterator<Schema>
  private let predicate: ((borrowing Row<Schema>) -> Bool)?
  private let transform: (borrowing Row<Schema>) -> T

  @_lifetime(copy base)
  internal init(_ base: borrowing TableIterator<Schema>,
                where predicate: ((borrowing Row<Schema>) -> Bool)? = nil,
                select transform: @escaping (borrowing Row<Schema>) -> T) {
    self.base = copy base
    self.predicate = predicate
    self.transform = transform
  }

  // MARK: Terminals

  /// Applies `body` to each projected value.
  public func forEach(_ body: (T) -> Void) {
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate?(value) ?? true {
        body(transform(value))
      }
    }
  }

  /// The first projected value whose row satisfies `predicate`.
  public func first(where predicate: (borrowing Row<Schema>) -> Bool) -> T? {
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if self.predicate?(value) ?? true, predicate(value) {
        return transform(value)
      }
    }
    return nil
  }

  /// Folds the projected values into `initial` with `next`.
  public func reduce<R>(_ initial: R, _ next: (R, T) -> R) -> R {
    var result = initial
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate?(value) ?? true {
        result = next(result, transform(value))
      }
    }
    return result
  }

  /// The number of projected values.
  public func count() -> Int {
    guard let predicate else { return base.count }
    var count = 0
    for row in 0 ..< base.count {
      guard let value = base[row] else { continue }
      if predicate(value) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - TableIterator entry points

extension TableIterator {
  /// Filters the rows by `predicate`, yielding a lazy `TypedFilter` stage.
  @_lifetime(copy self)
  public func `where`(_ predicate: @escaping (borrowing Row<Schema>) -> Bool)
      -> TypedFilter<Schema> {
    TypedFilter(self, predicate)
  }

  /// Maps each row through `transform`, yielding a lazy `TypedProjection`.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Row<Schema>) -> T)
      -> TypedProjection<Schema, T> {
    TypedProjection(self, select: transform)
  }

  /// Maps the rows satisfying `predicate` through `transform`.
  ///
  /// This is the common-case entry point; `where(_:).select(_:)` reads better
  /// when a query is built up incrementally.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Row<Schema>) -> T,
                        where predicate: @escaping (borrowing Row<Schema>)
                            -> Bool)
      -> TypedProjection<Schema, T> {
    TypedProjection(self, where: predicate, select: transform)
  }
}
