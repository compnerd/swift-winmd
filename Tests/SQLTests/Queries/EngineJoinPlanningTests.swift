// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Hash-join tests

/// A join catalog whose inner `Parent` is UNSORTED (so its join key is not
/// seekable and the executor hashes it) and tallies its row reads — to prove the
/// hash build scans the inner exactly once rather than once per outer record.
private func hashable() -> (catalog: EngineMemory, reads: EngineCounter) {
  let reads = EngineCounter()
  let parent = [
    EngineField(name: "Id", type: .integer),
    EngineField(name: "Name", type: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    EngineField(name: "Pid", type: .integer),
    EngineField(name: "Kid", type: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(9), .text("Orphan")],
  ] as Array<Array<Value>>

  let catalog = EngineMemory([
    "Parent": FixtureRelation(parent, parents, counter: reads),
    "Child": FixtureRelation(child, children),
  ])
  return (catalog, reads)
}

struct EngineHashJoinTests {
  @Test func `a hash join over an unsorted inner scans it exactly once`() throws {
    // `Parent` is unsorted, so its `Id` is not seekable and the join hashes it.
    // Four outer children probe the map, but the inner is read only three times
    // — its row count — not twelve (once per outer).
    let (catalog, reads) = hashable()
    let rows = try catalog.run(engineParse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
    #expect(reads.reads == 3)
  }

  @Test func `a coded-index inner key seeks rather than hashing the whole inner`() throws {
    // The join strategy is chosen by probing the inner key for seekability. A
    // decoded coded-index column is 1-based and rejects the null reference `0`,
    // so probing with `0` would call it unseekable and hash every inner row;
    // probing with a valid `1` finds it seekable, so a selective join seeks the
    // coded run instead. `Attribute.Parent` is such a column (stored raw
    // `(Id << 2) | tag`, decoded to a Id), and one `Type` (Id 6) probes it.
    let reads = EngineCounter()
    let type = [EngineField(name: "Id", type: .integer)]
    let types = [[.integer(6)]] as Array<Array<Value>>
    let attribute = [
      EngineField(name: "Parent", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let attributes = [
      [.integer(0), .text("null-ref")],
      [.integer(4), .text("td1")],
      [.integer(8), .text("td2")],
      [.integer(16), .text("td4")],
      [.integer(20), .text("td5")],
      [.integer(24), .text("td6")],
    ] as Array<Array<Value>>
    let catalog = EngineMemory([
      "Type": FixtureRelation(type, types),
      "Attribute": FixtureRelation(attribute, attributes, coded: 0,
                                   counter: reads),
    ])
    let rows = try catalog.run(engineParse("""
        SELECT Attribute.Name FROM Type
          JOIN Attribute ON Attribute.Parent = Type.Id
        """))
    #expect(rows == [[.text("td6")]])
    // Seeked: only the `Parent = 6` run (the single `td6` row) is read, not all
    // six. Before the fix — probing seekability with `0` — the coded column
    // tested unseekable and the join hashed, reading every attribute row.
    #expect(reads.reads == 1)
  }

  @Test func `an empty outer skips the hash build of an unseekable inner`() throws {
    // A contradictory outer WHERE prunes every `Child`, so the outer is empty
    // and no probe can match. The inner `Parent` is unsorted (unseekable), so
    // the join would hash it — but with no probes the build is pointless. The
    // empty-outer short-circuit returns before scanning, so ZERO inner rows are
    // read; the nested-loop path this replaced already read none for an empty
    // outer, and a large unseekable inner must not be fully scanned to answer
    // nothing.
    let (catalog, reads) = hashable()
    let rows = try catalog.run(engineParse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid < 0
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test func `an all-NULL-key outer skips the hash build of an unseekable inner`() throws {
    // The outer is NON-empty but every `Child.Pid` is NULL (a `WHERE Pid IS
    // NULL` keeps only the null-keyed rows), and a NULL key joins to nothing —
    // so no probe can match. The inner `Parent` is unsorted (unseekable), so the
    // join would hash it; but with no non-null probe the build is pointless. The
    // no-probe guard returns before scanning, so ZERO inner rows are read — the
    // nested-loop path this replaced read none for an all-null outer too.
    let reads = EngineCounter()
    let parent = [
      EngineField(name: "Id", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      EngineField(name: "Pid", type: .integer),
      EngineField(name: "Kid", type: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nemo")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let catalog = EngineMemory([
      "Parent": FixtureRelation(parent, parents, counter: reads),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(engineParse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid IS NULL
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test func `the hash probe and the seek probe return identical results`() throws {
    // The sorted `Parent` seeks; its unsorted twin hashes. Both inner orderings
    // must agree — the hash preserves the seek path's outer-major, inner-cursor
    // order.
    let seek = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """)
    let hash = try engineJoin("""
        SELECT P.Name, Child.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid
        """)
    #expect(hash == seek)
    #expect(hash == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a hash join emits matches outer-major in inner cursor order`() throws {
    // The unsorted twin forces the hash path. Without an ORDER BY the result
    // must be outer-major (each child in scan order), and a bucket's inner rows
    // in the inner's cursor order — exactly the nested loop's order.
    let forced = try engineJoin("""
        SELECT Child.Name, P.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid
        """)
    #expect(forced == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test func `a NULL key joins to nothing under the hash path`() throws {
    // The child with a NULL foreign key is the outer row; a NULL key hashes to
    // nothing, and a NULL inner key is never bucketed. `Parent` here is unsorted
    // so the join hashes.
    let parent = [
      EngineField(name: "Id", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      EngineField(name: "Pid", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nobody")],
      [.integer(2), .text("Bob")],
    ] as Array<Array<Value>>
    let catalog = EngineMemory([
      "Parent": FixtureRelation(parent, parents),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(engineParse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test func `a seekable inner filter seeks the hash inner rather than scanning it`() throws {
    // `Parent.Code` (the join key) is unseekable, so the join hashes the inner;
    // `Parent.Id` is sorted (seekable and ordered). `Child JOIN Parent ON
    // Parent.Code = Child.Code WHERE Parent.Id < 0` pushes `Parent.Id < 0` onto
    // the inner. Applied DURING inner materialisation, that contradictory
    // seekable filter seeks the inner to an empty run — every `Id` is positive —
    // so ZERO Parent rows are read and the query returns []. Before the fix the
    // filter rode the residual ABOVE the join, so the whole inner was scanned and
    // bucketed (three reads) before the filter matched none of it.
    let reads = EngineCounter()
    let parent = [
      EngineField(name: "Id", type: .integer),
      EngineField(name: "Code", type: .integer),
    ]
    let parents = [
      [.integer(1), .integer(10)],
      [.integer(2), .integer(20)],
      [.integer(3), .integer(30)],
    ] as Array<Array<Value>>
    let child = [
      EngineField(name: "Code", type: .integer),
      EngineField(name: "Kid", type: .text),
    ]
    let children = [
      [.integer(10), .text("Ann")],
      [.integer(20), .text("Bob")],
    ] as Array<Array<Value>>
    // `Parent` is sorted on `Id` (column 0), so `Id` seeks but the join key
    // `Code` (column 1) does not — forcing the hash path.
    let catalog = EngineMemory([
      "Parent": FixtureRelation(parent, parents, sorted: 0, counter: reads),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(engineParse("""
        SELECT Child.Kid, Parent.Id FROM Child
          JOIN Parent ON Parent.Code = Child.Code WHERE Parent.Id < 0
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }
}

// MARK: - Streaming-product tests

struct EngineStreamingProductTests {
  @Test func `a join whose inner is a view leaves a residual product-under-select`() throws {
    // The nest rewrite folds a bare scan into an index-nested join, but the
    // inner here is the `Adults` VIEW (a `derived` leaf), so nest cannot fire
    // and the level stays a `select` over a `product` — the shape the streaming
    // executor fuses.
    let catalog = try engineViews()
    let select = try engineParse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineResidual(plan))
  }

  @Test func `the streamed product filters row by row to the right rows`() throws {
    // `Adults` is Parent rows with Id >= 2 (Key 2 → Bee, 3 → Cid); only the
    // child whose Pid equals a Key survives — Bob (Pid 2) against Bee.
    let catalog = try engineViews()
    let rows = try catalog.run(engineParse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }

  @Test func `the streamed product equals the eager product filtered`() throws {
    // Cross the two inputs by hand — every child paired with every adult in
    // outer-major order — and keep the pairs the ON equality admits. The fused
    // streaming operator must yield exactly this, in this order.
    let catalog = try engineViews()
    let children = try catalog.run(engineParse("SELECT Name, Pid FROM Child"))
    let adults = try catalog.run(engineParse("SELECT Label, Key FROM Adults"))

    var eager = Array<Array<Value>>()
    for child in children {
      for adult in adults where child[1] == adult[1] {
        eager.append([child[0], adult[0]])
      }
    }

    let streamed = try catalog.run(engineParse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(streamed == eager)
  }

  @Test func `a residual product with UNKNOWN pairs drops them`() throws {
    // A NULL-keyed pair evaluates the ON equality to UNKNOWN, which the fused
    // filter drops exactly as `admitted` would — no NULL child reaches a match.
    let child = [
      EngineField(name: "Pid", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let children = [
      [.integer(2), .text("Bob")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let adults = try View(query: engineSelect("""
        SELECT Id, Name FROM Base WHERE Id >= 2
        """), columns: ["Key", "Label"])
    let base = [
      EngineField(name: "Id", type: .integer),
      EngineField(name: "Name", type: .text),
    ]
    let bases = [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ] as Array<Array<Value>>
    let catalog = EngineMemory([
      "Child": FixtureRelation(child, children),
      "Base": FixtureRelation(base, bases, sorted: 0),
    ], views: ["Adults": adults])
    let rows = try catalog.run(engineParse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }
}

