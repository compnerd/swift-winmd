// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct RequiredReferenceTests {
  // A required reference must name a row, so the null value (0) in such a
  // column is malformed metadata rather than an absent edge. The typed
  // accessors that front required references route through `Row.required`,
  // which throws `.BadImageFormat` instead of trapping on the missing row.
  //
  // This hand-builds the smallest database carrying a single `InterfaceImpl`
  // (#9) whose `Class` (a required simple `TypeDef` index) is null:
  //   InterfaceImpl[0].Class = 0  → the null reference
  //   InterfaceImpl[0].Interface = 0  → an unused coded cell
  private static let record: Array<UInt8> = [
    // InterfaceImpl[0]: Class = 0 (null), Interface = 0.
    0x00, 0x00, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  // Both columns are narrow (2-byte) indices, so the stride is 4.
  private static let relations: Array<Table> = [
    Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 0 ..< 4,
          wide: 0, stride: 4),
  ]

  private static let valid: UInt64 = 1 << 9

  @Test("a null required reference throws rather than traps")
  func nullRequiredReference() throws {
    let storage = Storage(bytes: RequiredReferenceTests.record.span.bytes,
                          relations: RequiredReferenceTests.relations.span,
                          strings: RequiredReferenceTests.empty.span.bytes,
                          blob: RequiredReferenceTests.empty.span.bytes,
                          guid: RequiredReferenceTests.empty.span.bytes,
                          valid: RequiredReferenceTests.valid, sorted: 0)
    let source = Row<Metadata.Tables.InterfaceImpl>(0,
                                                    RequiredReferenceTests.relations[0],
                                                    storage)
    // `InterfaceImpl.Class` is a required reference; with `Class == 0` the
    // accessor must throw `.BadImageFormat`, not force-unwrap a null resolve.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.Class }
  }
}
