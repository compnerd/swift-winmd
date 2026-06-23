// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct ReferencingTests {
  // Reverse navigation reads the owning table out of `relations`, so this
  // hand-builds a small multi-table database: `TypeDef` (#2, the target) and
  // `NestedClass` (#41, the owner). `NestedClass.NestedClass` (ordinal 0) is a
  // simple `TypeDef` index and the table's intrinsic sort key, so the rows are
  // laid out ordered by it. ECMA-335 rows are 1-based, so a stored value `N`
  // names the 0-based TypeDef row `N - 1`:
  //   NestedClass[0].NestedClass = 1  → TypeDef[0]
  //   NestedClass[1].NestedClass = 2  → TypeDef[1]
  //   NestedClass[2].NestedClass = 2  → TypeDef[1]
  //   NestedClass[3].NestedClass = 4  → TypeDef[3]
  // so the rows referencing TypeDef[1] are the contiguous run [1, 3).
  private static let record: Array<UInt8> = [
    // TypeDef[0..3]: four 14-byte rows, all zero (only the row count matters
    // for the reverse lookup; no columns are read off the target).
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0..3]: NestedClass index then EnclosingClass index, ordered
    // by NestedClass: 1, 2, 2, 4.
    0x01, 0x00, 0x09, 0x00,
    0x02, 0x00, 0x09, 0x00,
    0x02, 0x00, 0x09, 0x00,
    0x04, 0x00, 0x09, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeDef.self, rows: 4, range: 0 ..< 56,
          wide: 0, stride: 14),
    Table(Metadata.Tables.NestedClass.self, rows: 4, range: 56 ..< 72,
          wide: 0, stride: 4),
  ]

  private static let valid: UInt64 = (1 << 2) | (1 << 41)

  // The NestedClass table number is 41; setting its `Sorted` bit declares the
  // table physically ordered on its key column.
  private static func with(_ sorted: UInt64,
                           _ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: ReferencingTests.record.span.bytes,
                          relations: ReferencingTests.relations.span,
                          strings: ReferencingTests.empty.span.bytes,
                          blob: ReferencingTests.empty.span.bytes,
                          guid: ReferencingTests.empty.span.bytes,
                          valid: ReferencingTests.valid, sorted: sorted)
    try body(storage)
  }

  // Collect the 0-based owning rows that `referencing` yields.
  private static func matches(_ storage: borrowing Storage,
                              _ target: borrowing Tuple)
      throws -> Array<Int> {
    var rows = Array<Int>()
    let filter = try storage.referencing(target,
                                         in: Metadata.Tables.NestedClass.self,
                                         by: 0)
    filter.forEach { rows.append($0.row) }
    return rows
  }

  @Test("finds the referencing run by binary search when sorted")
  func sortedBinarySearch() throws {
    // NestedClass is sorted on its key (ordinal 0), so the run referencing
    // TypeDef[1] is found by binary search: rows 1 and 2.
    try ReferencingTests.with(1 << 41) { storage in
      let target = Tuple(1, ReferencingTests.relations[0], storage)
      let rows = try ReferencingTests.matches(storage, target)
      #expect(rows == [1, 2])
    }
  }

  @Test("falls back to a scan when unsorted and agrees")
  func unsortedScanAgrees() throws {
    // With the `Sorted` bit clear the same query falls back to a linear scan
    // and must return the identical matches.
    try ReferencingTests.with(0) { storage in
      let target = Tuple(1, ReferencingTests.relations[0], storage)
      let rows = try ReferencingTests.matches(storage, target)
      #expect(rows == [1, 2])
    }
  }

  @Test("sorted and scan paths agree for every target")
  func sortedAndScanAgree() throws {
    // Every target row resolves to the same set of owners under both paths.
    for row in 0 ..< 4 {
      var sorted = Array<Int>()
      var scanned = Array<Int>()
      try ReferencingTests.with(1 << 41) { storage in
        let target = Tuple(row, ReferencingTests.relations[0], storage)
        sorted = try ReferencingTests.matches(storage, target)
      }
      try ReferencingTests.with(0) { storage in
        let target = Tuple(row, ReferencingTests.relations[0], storage)
        scanned = try ReferencingTests.matches(storage, target)
      }
      #expect(sorted == scanned)
    }
  }

  @Test("yields no owners for an unreferenced target")
  func zeroMatches() throws {
    // TypeDef[2] (stored value 3) is named by no NestedClass row.
    try ReferencingTests.with(1 << 41) { storage in
      let target = Tuple(2, ReferencingTests.relations[0], storage)
      let sorted = try ReferencingTests.matches(storage, target)
      #expect(sorted.isEmpty)
    }
    try ReferencingTests.with(0) { storage in
      let target = Tuple(2, ReferencingTests.relations[0], storage)
      let scanned = try ReferencingTests.matches(storage, target)
      #expect(scanned.isEmpty)
    }
  }

  @Test("rejects a reverse lookup by an out-of-range column ordinal")
  func columnOrdinalOutOfRange() throws {
    // A negative ordinal or one at/beyond the owner's column count names no
    // field; `referencing` must throw rather than trap on `schema.fields`.
    ReferencingTests.with(0) { storage in
      let target = Tuple(0, ReferencingTests.relations[0], storage)
      let width = Metadata.Tables.NestedClass.fields.count
      #expect(throws: WinMDError.InvalidColumn) {
        _ = try storage.referencing(target,
                                    in: Metadata.Tables.NestedClass.self,
                                    by: -1)
      }
      #expect(throws: WinMDError.InvalidColumn) {
        _ = try storage.referencing(target,
                                    in: Metadata.Tables.NestedClass.self,
                                    by: width)
      }
    }
  }

  @Test("rejects a reverse lookup against the wrong table")
  func simpleIndexTableMismatch() throws {
    // `referencing` by a simple `TypeDef` index against a `NestedClass` target
    // is a usage error: the index does not name that table.
    ReferencingTests.with(0) { storage in
      let target = Tuple(0, ReferencingTests.relations[1], storage)
      #expect(throws: WinMDError.InvalidColumn) {
        _ = try storage.referencing(target,
                                    in: Metadata.Tables.NestedClass.self,
                                    by: 0)
      }
    }
  }
}

// A coded-index reverse lookup over an unsorted owner. `CustomAttribute` (#12)
// holds its owner in `Parent` (ordinal 0), a `HasCustomAttribute` coded index.
// `TypeDef` is the fourth table of that index (tag 3) and the index uses 5 tag
// bits, so a row naming TypeDef[r] stores `((r + 1) << 5) | 3`.
struct ReferencingCodedTests {
  // TypeDef[0]: 14 bytes (only the row count matters). Then two CustomAttribute
  // rows whose `Parent` names TypeDef[0] (encoded 0x23) and a third naming a
  // different target. Columns: Parent (HasCustomAttribute), Type
  // (CustomAttributeType), Value (Blob) — all narrow, stride 6.
  private static let record: Array<UInt8> = [
    // TypeDef[0].
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]: Parent = ((0 + 1) << 5) | 3 = 0x23 → TypeDef[0].
    0x23, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[1]: Parent = 0x43 = ((1 + 1) << 5) | 3 → TypeDef[1].
    0x43, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[2]: Parent = 0x23 → TypeDef[0] again.
    0x23, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 14,
          wide: 0, stride: 14),
    Table(Metadata.Tables.CustomAttribute.self, rows: 3, range: 14 ..< 32,
          wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = (1 << 2) | (1 << 12)

  @Test("scans an unsorted owner by a coded index")
  func codedReverseScan() throws {
    // CustomAttribute is left unsorted (`Sorted` clear), so the reverse lookup
    // scans; the rows naming TypeDef[0] through `Parent` are 0 and 2.
    let storage = Storage(bytes: ReferencingCodedTests.record.span.bytes,
                          relations: ReferencingCodedTests.relations.span,
                          strings: ReferencingCodedTests.empty.span.bytes,
                          blob: ReferencingCodedTests.empty.span.bytes,
                          guid: ReferencingCodedTests.empty.span.bytes,
                          valid: ReferencingCodedTests.valid, sorted: 0)
    let target = Tuple(0, ReferencingCodedTests.relations[0], storage)
    var rows = Array<Int>()
    let filter =
        try storage.referencing(target,
                                in: Metadata.Tables.CustomAttribute.self,
                                by: 0)
    filter.forEach { rows.append($0.row) }
    #expect(rows == [0, 2])
  }

  // `CustomAttribute.Type` (ordinal 1) is a `CustomAttributeType` coded index.
  // That index names five slots over three tag bits, but tags 0, 1, and 4 are
  // reserved and modelled as `nil` entries; only `MethodDef` (2) and `MemberRef`
  // (3) are real tables. A reverse lookup whose target is a `Module` row must be
  // rejected: `Module` is not among the index's tables, so `tag(of:in:)` yields
  // nil and `referencing` throws `.InvalidColumn`.
  //
  // This locks the Option-A behaviour. Were the reserved slots still the old
  // `Module` placeholders, `tag(of: Module)` would find one (tag 0) and the
  // lookup would silently scan instead of throwing.
  @Test("rejects a reverse lookup whose target is a reserved coded-index table")
  func reservedCodedIndexTarget() throws {
    // A single Module row (#0): Generation (constant, 2 bytes) + Name (string) +
    // Mvid + EncId + EncBaseId (guid each), all narrow ⇒ stride 10; cells zero.
    // A single CustomAttribute row (#12, stride 6) follows so the owning table is
    // present (`referencing` first checks the owner is a valid table).
    let record = Array<UInt8>(repeating: 0, count: 16)
    let relations: Array<Table> = [
      Table(Metadata.Tables.Module.self, rows: 1, range: 0 ..< 10,
            wide: 0, stride: 10),
      Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 10 ..< 16,
            wide: 0, stride: 6),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ReferencingCodedTests.empty.span.bytes,
                          blob: ReferencingCodedTests.empty.span.bytes,
                          guid: ReferencingCodedTests.empty.span.bytes,
                          valid: (1 << 0) | (1 << 12), sorted: 0)
    let target = Tuple(0, relations[0], storage)
    // `Type` (ordinal 1) is a `CustomAttributeType` coded index whose tables omit
    // `Module`; the reverse lookup must reject it rather than scan.
    #expect(throws: WinMDError.InvalidColumn) {
      _ = try storage.referencing(target,
                                  in: Metadata.Tables.CustomAttribute.self,
                                  by: 1)
    }
  }
}
