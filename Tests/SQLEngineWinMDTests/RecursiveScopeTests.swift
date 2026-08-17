// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import SQLEngineWinMD

import SQLEngine
@testable import WinMD

/// De-risks the closure render's scope-chain resolution: a `WITH RECURSIVE` CTE
/// walking the virtual, decoded coded-index column `ResolutionScope_TypeRef`
/// through a `TypeRef` nesting chain to its terminal scope, classifying each
/// reference local or external by whether that terminal resolves to the
/// `Module`. It proves the planner resolves a decoded coded-index column inside
/// a recursive CTE arm and that a `WITH RECURSIVE` runs through the adapter's
/// `run` — the substrate the `requires.sql`/`references.sql` resolution rests
/// on.
struct RecursiveScopeTests {
  // Four `TypeRef` rows (6-byte narrow rows: ResolutionScope coded index,
  // TypeName, TypeNamespace), forming two nesting chains. ECMA-335 rows are
  // 1-based, so a stored index `N` names the 0-based row `N - 1`, and a
  // `ResolutionScope` coded cell is `(row << 2) | tag` with the tag ordering
  // Module=0, ModuleRef=1, AssemblyRef=2, TypeRef=3.
  //
  //   TypeRef[0] Outer(AssemblyRef): RS=(1<<2)|2=6  → external terminal
  //   TypeRef[1] Inner(TypeRef→[0]): RS=(1<<2)|3=7  → nested under Outer[0]
  //   TypeRef[2] Outer(Module):      RS=(1<<2)|0=4  → local terminal
  //   TypeRef[3] Inner(TypeRef→[2]): RS=(3<<2)|3=15 → nested under Outer[2]
  //
  // Chain [1]→[0] terminates at an AssemblyRef (external); chain [3]→[2]
  // terminates at the Module (local). A nested reference carries an empty
  // namespace, as a real nested `TypeRef` does.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]: RS=6, TypeName=7 (Outer), TypeNamespace=13 (NS).
    0x06, 0x00, 0x07, 0x00, 0x0d, 0x00,
    // TypeRef[1]: RS=7, TypeName=1 (Inner), TypeNamespace=0 (empty).
    0x07, 0x00, 0x01, 0x00, 0x00, 0x00,
    // TypeRef[2]: RS=4, TypeName=7 (Outer), TypeNamespace=13 (NS).
    0x04, 0x00, 0x07, 0x00, 0x0d, 0x00,
    // TypeRef[3]: RS=15, TypeName=1 (Inner), TypeNamespace=0 (empty).
    0x0f, 0x00, 0x01, 0x00, 0x00, 0x00,
  ]

  // "\0Inner\0Outer\0NS\0": Inner@1, Outer@7, NS@13, empty namespace @0.
  private static let strings: Array<UInt8> = [
    0x00,
    0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00,
    0x4f, 0x75, 0x74, 0x65, 0x72, 0x00,
    0x4e, 0x53, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 4, range: 0 ..< 24,
                wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = 1 << 1

  /// Runs `sql` over a `WinMDDatabase` bound to the assembled `TypeRef` store.
  private static func run(_ sql: String) throws -> Array<Array<Value>> {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    let database = WinMDDatabase(storage)
    return try database.run(sql)
  }

  @Test func `walks a nesting chain to its terminal scope`() throws {
    // The recursive CTE seeds each `TypeRef` as its own chain start, then walks
    // `ResolutionScope_TypeRef` to the enclosing reference until the terminal
    // (its `ResolutionScope_TypeRef` NULL) — classified local when that
    // terminal's `ResolutionScope_Module` is non-null, external otherwise. Both
    // top-level terminals and both nested references classify by the terminal,
    // proving the decoded column resolves inside the recursive arm.
    let rows = try RecursiveScopeTests.run("""
      WITH RECURSIVE chain(start, node) AS (
        SELECT r.Id, r.Id FROM TypeRef r
        UNION ALL
        SELECT c.start, r.ResolutionScope_TypeRef
        FROM chain c
        JOIN TypeRef r ON r.Id = c.node
        WHERE r.ResolutionScope_TypeRef IS NOT NULL
      )
      SELECT
        c.start,
        CASE WHEN t.ResolutionScope_Module IS NOT NULL
             THEN 'local' ELSE 'external' END
      FROM chain c
      JOIN TypeRef t ON t.Id = c.node
      WHERE t.ResolutionScope_TypeRef IS NULL
      ORDER BY c.start
      """)
    #expect(rows == [
      [.integer(1), .text("external")], // Outer under AssemblyRef
      [.integer(2), .text("external")], // Inner under Outer[external]
      [.integer(3), .text("local")],    // Outer under Module
      [.integer(4), .text("local")],    // Inner under Outer[local]
    ])
  }
}
