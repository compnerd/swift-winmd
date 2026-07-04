// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The closure query combinators over any `Scan`.
///
/// A query is a borrowed traversal of the mapped buffer: filtering with `where`
/// and mapping with `select` build lazy `~Escapable` stages that store escapable
/// closures of the form `(borrowing Base.Element) -> …`, while the scan and the
/// transiently materialised row view stay on the borrowed view side of the
/// escape boundary. Nothing is materialised and nothing allocates per row;
/// stages compose and the scan runs only when a terminal consumes it.
///
/// The combinators are generic over the `Scan` they walk, so the one set runs
/// over both the typed `TableIterator<Schema>` — handing each stage a borrowed
/// `Row<Schema>`, whose predicates and projections address columns with
/// leading-dot `Column` tokens (`$0[.TypeName]`) — and the type-erased
/// `Cursor`, handing each stage a `Tuple` addressed positionally.
///
/// A projection must yield an escapable value. `.select({ $0 })` does not
/// surface the row — it silently infers `T = ()`, because a row view cannot
/// escape the closure. To surface rows themselves, hand them to the
/// `(borrowing Base.Element) -> Void` callback of `forEach` rather than
/// returning them.

// MARK: - Filter

/// A lazy filtered stage over a `Scan`.
///
/// It holds the base scan and a predicate; the predicate is evaluated only when
/// a terminal consumes the stage.
public struct Filter<Base: Scan & ~Escapable>: ~Escapable {
  private let base: Base
  private let predicate: (borrowing Base.Element) -> Bool

  @_lifetime(copy base)
  internal init(_ base: borrowing Base,
                _ predicate: @escaping (borrowing Base.Element) -> Bool) {
    self.base = copy base
    self.predicate = predicate
  }

  /// Maps each surviving row through `transform`, yielding an escapable value.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Base.Element) -> T)
      -> Projection<Base, T> {
    Projection(base, where: predicate, select: transform)
  }

  // MARK: Terminals

  /// Applies `body` to each surviving row.
  public func forEach(_ body: (borrowing Base.Element) -> Void) {
    for row in 0 ..< base.count {
      guard let value = base.element(row) else { continue }
      if predicate(value) {
        body(value)
      }
    }
  }

  /// The first surviving row satisfying `predicate`, passed to `body`.
  ///
  /// Returns the escapable value `body` produces, or `nil` if no row matches.
  public func first<T>(where predicate: (borrowing Base.Element) -> Bool,
                       _ body: (borrowing Base.Element) -> T) -> T? {
    for row in 0 ..< base.count {
      guard let value = base.element(row) else { continue }
      if self.predicate(value), predicate(value) {
        return body(value)
      }
    }
    return nil
  }

  /// Folds the surviving rows into `initial` with `next`.
  public func reduce<R>(_ initial: R,
                        _ next: (R, borrowing Base.Element) -> R) -> R {
    var result = initial
    for row in 0 ..< base.count {
      guard let value = base.element(row) else { continue }
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
      guard let value = base.element(row) else { continue }
      if predicate(value) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - Projection

/// A lazy projected stage over a `Scan`.
///
/// It holds the base scan, an optional predicate, and a transform mapping a
/// surviving row to an escapable value; both run only when a terminal consumes
/// the stage.
public struct Projection<Base: Scan & ~Escapable, T>: ~Escapable {
  private let base: Base
  private let predicate: ((borrowing Base.Element) -> Bool)?
  private let transform: (borrowing Base.Element) -> T

  @_lifetime(copy base)
  internal init(_ base: borrowing Base,
                where predicate: ((borrowing Base.Element) -> Bool)? = nil,
                select transform: @escaping (borrowing Base.Element) -> T) {
    self.base = copy base
    self.predicate = predicate
    self.transform = transform
  }

  // MARK: Terminals

  /// Applies `body` to each projected value.
  public func forEach(_ body: (T) -> Void) {
    for row in 0 ..< base.count {
      guard let value = base.element(row) else { continue }
      if predicate?(value) ?? true {
        body(transform(value))
      }
    }
  }

  /// The first projected value whose row satisfies `predicate`.
  public func first(where predicate: (borrowing Base.Element) -> Bool) -> T? {
    for row in 0 ..< base.count {
      guard let value = base.element(row) else { continue }
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
      guard let value = base.element(row) else { continue }
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
      guard let value = base.element(row) else { continue }
      if predicate(value) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - Scan entry points

extension Scan where Self: ~Escapable {
  /// Filters the rows by `predicate`, yielding a lazy `Filter` stage.
  @_lifetime(copy self)
  public func `where`(_ predicate: @escaping (borrowing Element) -> Bool)
      -> Filter<Self> {
    Filter(self, predicate)
  }

  /// Maps each row through `transform`, yielding a lazy `Projection` stage.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Element) -> T)
      -> Projection<Self, T> {
    Projection(self, select: transform)
  }

  /// Maps the rows satisfying `predicate` through `transform`.
  ///
  /// This is the common-case entry point; `where(_:).select(_:)` reads better
  /// when a query is built up incrementally.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Element) -> T,
                        where predicate: @escaping (borrowing Element) -> Bool)
      -> Projection<Self, T> {
    Projection(self, where: predicate, select: transform)
  }
}
