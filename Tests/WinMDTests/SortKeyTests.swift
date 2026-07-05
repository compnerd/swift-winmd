// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct SortKeyTests {
  @Test func `sorted tables name their key column ordinal`() {
    // The key is the ordinal of the column the table is physically ordered by
    // (ECMA-335 §II.22), resolved from each schema's own column order.
    #expect(Metadata.Tables.NestedClass.key == 0)
    #expect(Metadata.Tables.ClassLayout.key == 2)
    #expect(Metadata.Tables.DeclSecurity.key == 1)
    #expect(Metadata.Tables.MethodSemantics.key == 2)
  }

  @Test func `unsorted tables have no key`() {
    // A table the specification does not sort inherits the `nil` default.
    #expect(Metadata.Tables.TypeDef.key == nil)
    #expect(Metadata.Tables.TypeRef.key == nil)
  }
}
