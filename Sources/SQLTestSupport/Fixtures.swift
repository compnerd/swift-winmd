// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine

/// A nullable integer and text fixture shared by expression tests whose result
/// type and NULL fallthrough depend on the same two rows.
public func nullable() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "Name": .text]) {
      Row(1, 10, "a")
      Row(2, nil, "b")
    }
  }
}

/// An empty `People(Name TEXT)` relation for schema-only expression derivation.
public func derivation() -> FixtureCatalog {
  FixtureCatalog(
    ["People": FixtureRelation([FixtureField(name: "Name", type: .text)], [])])
}

/// The common outer, inner, and NULL-bearing relations used by membership and
/// quantified subquery tests.
public func subqueries() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer]) {
      Row(1, 10)
      Row(2, 20)
      Row(3, nil)
      Row(4, 30)
    }
    Relation("S", ["V": .integer, "Flag": .integer]) {
      Row(10, 1)
      Row(20, 1)
      Row(99, 0)
    }
    Relation("N", ["V": .integer]) {
      Row(2)
      Row(nil)
    }
  }
}
