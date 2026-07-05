// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct RowLayoutTests {
  // The `TypeDef` schema is a representative mix of column kinds:
  //   0 Flags         constant(4)
  //   1 TypeName      index (String Heap)
  //   2 TypeNamespace index (String Heap)
  //   3 Extends       index (TypeDefOrRef Coded)
  //   4 FieldList     index (FieldDef Simple)
  //   5 MethodList    index (MethodDef Simple)
  // Its narrow offsets are therefore [0, 4, 6, 8, 10, 12] and the narrow
  // stride is 14.
  typealias Schema = Metadata.Tables.TypeDef

  @Test func `computes narrow column offsets from the schema`() {
    #expect(Schema.offset(0) == 0)
    #expect(Schema.offset(1) == 4)
    #expect(Schema.offset(2) == 6)
    #expect(Schema.offset(3) == 8)
    #expect(Schema.offset(4) == 10)
    #expect(Schema.offset(5) == 12)
  }

  @Test func `gives offsets and widths for an all-narrow table`() {
    // No wide indices: offsets are the narrow offsets, every index is 2 bytes,
    // and the stride is the narrow stride.
    let table = Table(Schema.self, rows: 0, range: 0 ..< 0, wide: 0, stride: 14)

    #expect(table.stride == 14)

    #expect(table.offset(0) == 0)
    #expect(table.width(0) == 4)

    #expect(table.offset(1) == 4)
    #expect(table.width(1) == 2)

    #expect(table.offset(5) == 12)
    #expect(table.width(5) == 2)
  }

  @Test func `shifts and widens columns past wide indices`() {
    // Widen TypeName (column 1) and FieldList (column 4) to 4-byte indices.
    // Each adds two bytes, so the stride grows by four and every column from
    // the first wide index onward shifts by the running popcount.
    let wide: UInt32 = (1 << 1) | (1 << 4)
    let table = Table(Schema.self, rows: 0, range: 0 ..< 0, wide: wide,
                      stride: 18)

    #expect(table.stride == 18)

    // A constant column is never widened and is unshifted at the front.
    #expect(table.offset(0) == 0)
    #expect(table.width(0) == 4)

    // A wide index: widened to 4 bytes, no preceding wide index to shift it.
    #expect(table.offset(1) == 4)
    #expect(table.width(1) == 4)

    // A narrow index after one wide index: shifted by two, still 2 bytes.
    #expect(table.offset(2) == 8)
    #expect(table.width(2) == 2)

    #expect(table.offset(3) == 10)
    #expect(table.width(3) == 2)

    // The second wide index: shifted by two and widened to 4 bytes.
    #expect(table.offset(4) == 12)
    #expect(table.width(4) == 4)

    // A narrow index after two wide indices: shifted by four (popcount path).
    #expect(table.offset(5) == 16)
    #expect(table.width(5) == 2)
  }
}
