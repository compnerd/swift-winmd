// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct FieldTests {
  // Two synthetic, narrow `TypeDef` rows backed by hand-built spans. The
  // schema's narrow stride is 14: Flags (4) + five 2-byte indices. The cells
  // are laid out so the rows carry distinct names and namespaces out of a tiny
  // strings heap.
  //   [0] Flags = 0x00000021, TypeName = 1 ("string0"),  TypeNamespace = 9 ("string1")
  //   [1] Flags = 0x00000000, TypeName = 17 ("string2"), TypeNamespace = 9 ("string1")
  private static let record: Array<UInt8> = [
    0x21, 0x00, 0x00, 0x00,
    0x01, 0x00,
    0x09, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x11, 0x00,
    0x09, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
  ]

  // A strings heap: "\0string0\0string1\0string2\0" — "string0" at 1, "string1" at 9, "string2" at 17.
  private static let strings: Array<UInt8> = [
    0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x30, 0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x31, 0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x32, 0x00,
  ]

  private static let empty = Array<UInt8>()

  // The open table is dense so the iterator can address both rows; the
  // strides are the sum of the columns' narrow widths.
  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 28,
          wide: 0, stride: 14),
  ]

  private static let valid: UInt64 = 1 << 2

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: FieldTests.record.span.bytes,
                          relations: FieldTests.relations.span,
                          strings: FieldTests.strings.span.bytes,
                          blob: FieldTests.empty.span.bytes,
                          guid: FieldTests.empty.span.bytes,
                          valid: FieldTests.valid, sorted: 0)
    try body(storage)
  }

  @Test("reads typed values through Column tokens")
  func tokenReads() throws {
    try FieldTests.with { storage in
      let table = FieldTests.relations[0]
      let row = Row<Metadata.Tables.TypeDef>(0, table, storage)

      // The token read agrees with the kind-validating generic `string`, and
      // recovers the column's domain type without an annotation.
      let name = row[.TypeName]
      let namespace = row[.TypeNamespace]
      let validated = try row.columns.string(1)
      let validatedNamespace = try row.columns.string(2)
      #expect(name == "string0")
      #expect(name == validated)
      #expect(namespace == "string1")
      #expect(namespace == validatedNamespace)

      // A typed-constant token wraps the raw cell in its COR flag domain type.
      let flags = row[.Flags]
      #expect(flags == CorTypeAttr(rawValue: 0x21))
      #expect(flags == row.Flags)
    }
  }

  @Test("filters and projects typed rows with where and select")
  func whereSelect() throws {
    try FieldTests.with { storage in
      let iterator =
          try storage.rows(of: Metadata.Tables.TypeDef.self)

      var names = Array<String>()
      iterator
        .select({ $0[.TypeName] },
                where: { $0[.TypeNamespace] == "string1" })
        .forEach { names.append($0) }
      #expect(names == ["string0", "string2"])
    }
  }

  @Test("filters typed rows with a value predicate")
  func wherePredicate() throws {
    try FieldTests.with { storage in
      let iterator =
          try storage.rows(of: Metadata.Tables.TypeDef.self)

      // Only the first row carries the flag bit; counting the survivors of the
      // typed predicate proves the stage reads the borrowed row's tokens.
      let count = iterator
        .where({ $0[.Flags].contains(.tdPublic) })
        .count()
      #expect(count == 1)
    }
  }

  @Test("projects the first row matching a typed predicate")
  func firstProjection() throws {
    try FieldTests.with { storage in
      let iterator =
          try storage.rows(of: Metadata.Tables.TypeDef.self)

      let first = iterator
        .select({ $0[.TypeName] })
        .first(where: { $0[.TypeName] == "string2" })
      #expect(first == "string2")
    }
  }
}
