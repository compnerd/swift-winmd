// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A typed token addressing a value column of a `Row<Schema>`.
///
/// A `Column` names a single value column by its ordinal and carries the recipe
/// for decoding that column's raw cell to a `Value`. Because a token is built
/// for a column of a statically known kind, it decodes directly through the
/// row's heap views — like the hand-written accessors do — rather than through
/// the kind-validating `Tuple.string`/`blob`/`guid`, so the read is
/// non-throwing.
///
/// A token is escapable: the `decode` closure reads the borrowed `Row` it is
/// handed but does not store it, so the row stays on the borrowed side of the
/// escape boundary. The token surfaces as leading-dot sugar on a row —
/// `row[.TypeName]` — and backs the hand-written value accessors and the typed
/// query combinators.
///
/// Foreign-key columns (simple/coded indices) are navigation, not values, and
/// are addressed by `resolve`/`list`/`referencing` instead; they have no token.
public struct Column<Schema: TableSchema, Value> {
  /// The ordinal of the column within the schema.
  internal let ordinal: Int

  /// Decodes the column's cell of the borrowed `row` to a `Value`.
  internal let decode: (borrowing Row<Schema>) -> Value

  internal init(_ ordinal: Int,
                _ decode: @escaping (borrowing Row<Schema>) -> Value) {
    self.ordinal = ordinal
    self.decode = decode
  }
}

extension Row {
  /// The value of the column the `field` token addresses.
  ///
  /// The typed read: `row[.TypeName]` resolves `Value` from the token, so the
  /// column's domain type is recovered without an annotation.
  public subscript<Value>(_ field: Column<Schema, Value>) -> Value {
    field.decode(self)
  }
}

/// A typed token addressing a `#Blob`-heap column of a `Row<Schema>`.
///
/// A blob is a borrowed view (`Blob` is `~Escapable`), so it cannot be the
/// `Value` of an escapable `Column` whose decode closure would return it.
/// `BlobColumn` is therefore a distinct token that names a blob column by its
/// ordinal; the read happens in the row subscript, which borrows the row and
/// resolves the cell through the "Blob" heap.
public struct BlobColumn<Schema: TableSchema> {
  /// The ordinal of the column within the schema.
  internal let ordinal: Int

  internal init(_ ordinal: Int) {
    self.ordinal = ordinal
  }
}

extension Row {
  /// The blob the column the `field` token addresses references.
  public subscript(_ field: BlobColumn<Schema>) -> Blob {
    @_lifetime(copy self)
    get { blobs[columns[field.ordinal]] }
  }

  /// The blob the column the `field` token addresses references, validating the
  /// `#Blob` entry's length prefix and extent so a malformed entry throws
  /// `.BadImageFormat` rather than trapping.
  ///
  /// The non-throwing subscript trusts the entry; this is the validating path
  /// the signature accessors open `.Signature` through before decoding.
  @_lifetime(copy self)
  public func blob(_ field: BlobColumn<Schema>) throws(WinMDError) -> Blob {
    try blobs.blob(at: columns[field.ordinal])
  }
}

/// A typed token addressing a simple-index foreign-key column of a
/// `Row<Schema>`.
///
/// Where a `Column` names a value column, a `Reference` names a *navigation*
/// column: a `simple` index whose target table is statically known. The token
/// carries the column's ordinal and, through its `Target` parameter, the
/// referenced schema, so `row.resolve(.Col)` recovers a typed `Row<Target>`
/// without an annotation. It is the forward, single-row counterpart of the
/// value `Column` token, and the owning-column descriptor a reverse
/// `database.referencing(_:by:)` consumes.
public struct Reference<Schema: TableSchema, Target: TableSchema> {
  /// The ordinal of the column within the schema.
  internal let ordinal: Int

  internal init(_ ordinal: Int) {
    self.ordinal = ordinal
  }
}

/// A typed token addressing a coded-index foreign-key column of a
/// `Row<Schema>`.
///
/// A coded index selects its target table at runtime from the stored tag, so
/// unlike `Reference` it carries no static `Target`: resolving it yields the
/// type-erased `Tuple`, which the caller narrows with `Row<Target>(_:)` once
/// the tag's table is known. The token still carries the owning `Schema` and
/// the column's ordinal, so it doubles as the owning-column descriptor for a
/// reverse `database.referencing(_:by:)`.
public struct CodedReference<Schema: TableSchema> {
  /// The ordinal of the column within the schema.
  internal let ordinal: Int

  internal init(_ ordinal: Int) {
    self.ordinal = ordinal
  }
}

/// A typed token addressing a list-valued foreign-key column of a
/// `Row<Schema>`.
///
/// A list column stores the start of a `[start, next-row's start)` run into the
/// `Target` table; `row.list(.Col)` opens a typed `TableIterator<Target>` over
/// that run. It is the forward, multi-row navigation counterpart of
/// `Reference`.
public struct List<Schema: TableSchema, Target: TableSchema> {
  /// The ordinal of the column within the schema.
  internal let ordinal: Int

  internal init(_ ordinal: Int) {
    self.ordinal = ordinal
  }
}

extension Row {
  /// The row the simple-index column the `reference` token addresses names, or
  /// `nil` if the reference is null.
  ///
  /// `row.resolve(.Col)` decodes the simple index through the generic
  /// `Tuple.resolve` and narrows the result to the token's statically known
  /// `Target`. The narrowing always succeeds for a well-formed simple index, so
  /// the result is `nil` only when the reference itself is null.
  @_lifetime(copy self)
  public func resolve<Target>(_ reference: Reference<Schema, Target>)
      throws(WinMDError) -> Row<Target>? {
    guard let tuple = try columns.resolve(reference.ordinal) else {
      return nil
    }
    return Row<Target>(tuple)
  }

  /// Resolves a REQUIRED reference, throwing `.BadImageFormat` if the column
  /// holds the null value — a required reference must name a row.
  @_lifetime(copy self)
  public func required<Target>(_ reference: Reference<Schema, Target>)
      throws(WinMDError) -> Row<Target> {
    guard let row = try resolve(reference) else { throw .BadImageFormat }
    return row
  }

  /// The tuple the coded-index column the `reference` token addresses names, or
  /// `nil` if the reference is null.
  ///
  /// A coded index's target table is chosen at runtime by its tag, so the
  /// result is the type-erased `Tuple`; narrow it with `Row<Target>(_:)` once
  /// the target table is known.
  @_lifetime(copy self)
  public func resolve(_ reference: CodedReference<Schema>)
      throws(WinMDError) -> Tuple? {
    try columns.resolve(reference.ordinal)
  }

  /// The rows of the `[start, next-row's start)` run the list column the `list`
  /// token addresses delimits.
  @_lifetime(copy self)
  public func list<Target>(_ list: List<Schema, Target>)
      throws(WinMDError) -> TableIterator<Target> {
    try self.list(for: list.ordinal)
  }
}
