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
