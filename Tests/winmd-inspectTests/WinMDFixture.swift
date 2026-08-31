// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@testable import WinMD

/// A compact in-target assembler for `#~` metadata test fixtures. It interns the
/// string and blob heaps, accumulates table rows, and computes the heap offsets
/// and per-table stream ranges a `Storage` reads — so a fixture declares its
/// rows and lets the assembler count the bytes, rather than hand-maintaining the
/// byte offsets and `range:` arithmetic every edit otherwise has to re-derive
/// (the recurring source of transcription bugs). It mirrors the row layout the
/// hand-built fixtures use exactly, so a fixture ported to it is behaviourally
/// identical.
///
/// Rows are 1-based (ECMA-335); `row` returns the new row's 1-based rid so a
/// later coded index can name it. Tokens are built with the `Coded` helpers.
final class WinMDFixture {
  private var strings: Array<UInt8> = [0]
  private var interned: Dictionary<String, Int> = [:]
  private var blobs: Array<UInt8> = [0]
  private var rows: Dictionary<Int, Array<UInt8>> = [:]

  /// The tables the assembler knows, each `number: stride`. The stream emits
  /// present tables in ascending table-number order, the order a `#~` stream and
  /// the reader agree on.
  static let stride: Dictionary<Int, Int> = [
    1: 6, 2: 14, 4: 6, 6: 14, 8: 6, 9: 4, 10: 6, 11: 6, 12: 6,
    0x1B: 2, 0x23: 20, 0x29: 4, 0x2A: 8,
  ]

  /// The table numbers a fixture includes even with no rows, so a view that
  /// joins them still resolves. `AssemblyRef`/`GenericParam` join only when a row
  /// is added, so they are present exactly when used.
  static let base = [1, 2, 4, 6, 8, 9, 10, 11, 12, 0x1B, 0x29]

  /// Interns `name` in the `#Strings` heap, returning its offset. The empty
  /// string is offset 0 (the heap's leading NUL).
  func string(_ name: String) -> Int {
    if name.isEmpty { return 0 }
    if let offset = interned[name] { return offset }
    let offset = strings.count
    interned[name] = offset
    strings.append(contentsOf: Array(name.utf8))
    strings.append(0)
    return offset
  }

  /// Appends `data` to the `#Blob` heap as a length-prefixed blob (single-byte
  /// length, the only width the fixtures need), returning its offset.
  func blob(_ data: Array<UInt8>) -> Int {
    let offset = blobs.count
    blobs.append(UInt8(data.count))
    blobs.append(contentsOf: data)
    return offset
  }

  /// Appends a row of `data` to `table` (a table number), returning its 1-based
  /// rid.
  @discardableResult
  func row(_ table: Int, _ data: Array<UInt8>) -> Int {
    rows[table, default: []].append(contentsOf: data)
    return rows[table]!.count / WinMDFixture.stride[table]!
  }

  private func schema(_ number: Int) -> TableSchema.Type {
    switch number {
    case 1: Metadata.Tables.TypeRef.self
    case 2: Metadata.Tables.TypeDef.self
    case 4: Metadata.Tables.FieldDef.self
    case 6: Metadata.Tables.MethodDef.self
    case 8: Metadata.Tables.Param.self
    case 9: Metadata.Tables.InterfaceImpl.self
    case 10: Metadata.Tables.MemberRef.self
    case 11: Metadata.Tables.Constant.self
    case 12: Metadata.Tables.CustomAttribute.self
    case 0x1B: Metadata.Tables.TypeSpec.self
    case 0x23: Metadata.Tables.AssemblyRef.self
    case 0x29: Metadata.Tables.NestedClass.self
    case 0x2A: Metadata.Tables.GenericParam.self
    default: fatalError("unknown table \(number)")
    }
  }

  /// Assembles the accumulated rows into a borrowed `Storage` and runs `body`
  /// over it. The present tables are the base set plus any table a row was added
  /// to (so `AssemblyRef`/`GenericParam` appear only when used); each emits in
  /// table-number order with its computed range, and `valid` marks them.
  func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let present = Set(WinMDFixture.base).union(rows.keys).sorted()
    var stream = Array<UInt8>()
    var tables = Array<Table>()
    var mask: UInt64 = 0
    for number in present {
      let stride = WinMDFixture.stride[number]!
      let data = rows[number] ?? []
      let start = stream.count
      stream.append(contentsOf: data)
      tables.append(Table(schema(number), rows: UInt32(data.count / stride),
                          range: start ..< stream.count, wide: 0,
                          stride: stride))
      mask |= (1 << number)
    }
    // Finalise every heap and the stream into immutable locals so their spans
    // are rooted in stable storage the borrowed `Storage` can depend on for the
    // duration of `body`, exactly as a static-property fixture's arrays are.
    let bytes = stream, relations = tables, valid = mask
    let heap = strings, pool = blobs, empty = Array<UInt8>()
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: heap.span.bytes, blob: pool.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}

/// The little-endian encodings and coded-index constructions ECMA-335 metadata
/// rows use, so a fixture spells a field the way the layout reads it.
enum Coded {
  static func u16(_ value: Int) -> Array<UInt8> {
    [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
  }
  static func u32(_ value: Int) -> Array<UInt8> {
    [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
     UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
  }
  /// A `TypeDefOrRef`/`ResolutionScope`-style coded index: `(rid << bits) | tag`.
  static func index(_ tag: Int, _ rid: Int, bits: Int = 2) -> Int {
    (rid << bits) | tag
  }
}
