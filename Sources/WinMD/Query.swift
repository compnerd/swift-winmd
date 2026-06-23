// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The closure query combinators over a generic `Cursor`.
///
/// A query is a borrowed traversal of the mapped buffer: filtering with `where`
/// and mapping with `select` build lazy `~Escapable` stages that store escapable
/// closures of the form `(borrowing Tuple) -> …`, while the cursor and the
/// transiently materialised `Tuple` stay on the borrowed view side of the
/// escape boundary. Nothing is materialised and nothing allocates per row;
/// stages compose and the scan runs only when a terminal consumes it.
///
/// A projection must yield an escapable value. `.select({ $0 })` does not
/// surface the row — it silently infers `T = ()`, because a `Tuple` cannot
/// escape the closure. To surface rows themselves, hand them to the
/// `(borrowing Tuple) -> Void` callback of `forEach` rather than returning them.

// MARK: - Filter

/// A lazy filtered stage over a `Cursor`.
///
/// It holds the base cursor and a predicate; the predicate is evaluated only
/// when a terminal consumes the stage.
public struct Filter: ~Escapable {
  private let base: Cursor
  private let predicate: (borrowing Tuple) -> Bool

  @_lifetime(copy base)
  internal init(_ base: borrowing Cursor,
                _ predicate: @escaping (borrowing Tuple) -> Bool) {
    self.base = copy base
    self.predicate = predicate
  }

  /// Maps each surviving row through `transform`, yielding an escapable value.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Tuple) -> T)
      -> Projection<T> {
    Projection(base, where: predicate, select: transform)
  }

  // MARK: Terminals

  /// Applies `body` to each surviving row.
  public func forEach(_ body: (borrowing Tuple) -> Void) {
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate(tuple) {
        body(tuple)
      }
    }
  }

  /// The first surviving row satisfying `predicate`, passed to `body`.
  ///
  /// Returns the escapable value `body` produces, or `nil` if no row matches.
  public func first<T>(where predicate: (borrowing Tuple) -> Bool,
                       _ body: (borrowing Tuple) -> T) -> T? {
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if self.predicate(tuple), predicate(tuple) {
        return body(tuple)
      }
    }
    return nil
  }

  /// Folds the surviving rows into `initial` with `next`.
  public func reduce<R>(_ initial: R,
                        _ next: (R, borrowing Tuple) -> R) -> R {
    var result = initial
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate(tuple) {
        result = next(result, tuple)
      }
    }
    return result
  }

  /// The number of surviving rows.
  public func count() -> Int {
    var count = 0
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate(tuple) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - Projection

/// A lazy projected stage over a `Cursor`.
///
/// It holds the base cursor, an optional predicate, and a transform mapping a
/// surviving row to an escapable value; both run only when a terminal consumes
/// the stage.
public struct Projection<T>: ~Escapable {
  private let base: Cursor
  private let predicate: ((borrowing Tuple) -> Bool)?
  private let transform: (borrowing Tuple) -> T

  @_lifetime(copy base)
  internal init(_ base: borrowing Cursor,
                where predicate: ((borrowing Tuple) -> Bool)? = nil,
                select transform: @escaping (borrowing Tuple) -> T) {
    self.base = copy base
    self.predicate = predicate
    self.transform = transform
  }

  // MARK: Terminals

  /// Applies `body` to each projected value.
  public func forEach(_ body: (T) -> Void) {
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate?(tuple) ?? true {
        body(transform(tuple))
      }
    }
  }

  /// The first projected value whose row satisfies `predicate`.
  public func first(where predicate: (borrowing Tuple) -> Bool) -> T? {
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if self.predicate?(tuple) ?? true, predicate(tuple) {
        return transform(tuple)
      }
    }
    return nil
  }

  /// Folds the projected values into `initial` with `next`.
  public func reduce<R>(_ initial: R, _ next: (R, T) -> R) -> R {
    var result = initial
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate?(tuple) ?? true {
        result = next(result, transform(tuple))
      }
    }
    return result
  }

  /// The number of projected values.
  public func count() -> Int {
    guard let predicate else { return base.count }
    var count = 0
    for row in 0 ..< base.count {
      guard let tuple = base[row] else { continue }
      if predicate(tuple) {
        count += 1
      }
    }
    return count
  }
}

// MARK: - Cursor entry points

extension Cursor {
  /// Filters the rows by `predicate`, yielding a lazy `Filter` stage.
  @_lifetime(copy self)
  public func `where`(_ predicate: @escaping (borrowing Tuple) -> Bool)
      -> Filter {
    Filter(self, predicate)
  }

  /// Maps each row through `transform`, yielding a lazy `Projection` stage.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Tuple) -> T)
      -> Projection<T> {
    Projection(self, select: transform)
  }

  /// Maps the rows satisfying `predicate` through `transform`.
  ///
  /// This is the common-case entry point; `where(_:).select(_:)` reads better
  /// when a query is built up incrementally.
  @_lifetime(copy self)
  public func select<T>(_ transform: @escaping (borrowing Tuple) -> T,
                        where predicate: @escaping (borrowing Tuple) -> Bool)
      -> Projection<T> {
    Projection(self, where: predicate, select: transform)
  }
}
