// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct PhysicalSchemaTests {
  // A `CustomAttributeType` coded index names the tables [reserved, reserved,
  // MethodDef, MemberRef, reserved]: only tags 2 and 3 name a table, the rest
  // are reserved. A reserved tag names no table, so it contributes no rows to
  // the index width — the width is fixed solely by the present targets. When
  // they fit under the compressed range (here one row each, far below 2^(16-3))
  // the index is 2 bytes; a reserved slot must not force it to 4.
  //
  // This builds the smallest tables stream that carries `CustomAttribute` (#12)
  // alongside its targets `MethodDef` (#6) and `MemberRef` (#10), then resolves
  // the layout the way the database does — through `relations`, which sizes the
  // `Type` column (column 1, a `CustomAttributeType` coded index) via
  // `PhysicalSchema.width(of:)`.
  @Test("sizes a coded column with reserved tags by its present targets only")
  func reservedTagsDoNotWiden() throws {
    // Header: Reserved(4), Major(1), Minor(1), HeapSizes(1), Reserved(1),
    // Valid(8), Sorted(8), then a 32-bit row count per present table. The three
    // present tables each carry a single row, comfortably below the compressed
    // range, so every index in them is narrow (2 bytes). The buffer is padded
    // well past any plausible record extent so `relations` stays in bounds.
    let valid: UInt64 = (1 << 6) | (1 << 10) | (1 << 12)
    var bytes = Array<UInt8>(repeating: 0, count: 256)
    // Valid at +8.
    for shift in 0 ..< 8 {
      bytes[8 + shift] = UInt8(truncatingIfNeeded: valid >> (shift * 8))
    }
    // One row each, in ascending table-number order: MethodDef, MemberRef,
    // CustomAttribute. Each row count is a 32-bit little-endian word at +24.
    for slot in 0 ..< 3 {
      bytes[24 + slot * 4] = 1
    }

    let stream = TablesStream(bytes.span.bytes, base: 0, limit: bytes.count)
    let relations = try stream.relations(PhysicalSchema(stream))

    guard let attributes = relations.first(where: {
      $0.number == Metadata.Tables.CustomAttribute.number
    }) else {
      Issue.record("CustomAttribute table was not opened"); return
    }

    // The `Type` column (column 1) is a `CustomAttributeType` coded index whose
    // only present targets are small, so it is a 2-byte index — the reserved
    // tags must not widen it to 4.
    #expect(attributes.width(1) == 2)

    // The `Parent` column is a `HasCustomAttribute` coded index over many
    // tables, all but `MethodDef` absent here. An absent target has no rows, so
    // it cannot force a wide index; the only present target carries one row, far
    // below the compressed range, so `Parent` is a narrow 2-byte index too. The
    // row is the narrow `Parent`, the narrow `Type`, and a narrow `Value` blob
    // index: 2 + 2 + 2 = 6 bytes.
    #expect(attributes.width(0) == 2)
    #expect(attributes.stride == 6)
  }
}
