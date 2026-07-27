// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

package import SQLEngine
internal import SQLStandard

internal import class Foundation.Bundle
internal import class Foundation.FileManager
internal import struct Foundation.Data
internal import struct Foundation.URL

// MARK: - Session

extension Session {
  /// Runs one SQL `statement` against the session, returning the rows a
  /// `SELECT` yields — or none for a `CREATE VIEW`, which registers its `View`,
  /// or a `CREATE FUNCTION`, which registers its scalar `Function` into the
  /// session's routines (each key case-folded, the way the catalog and routines
  /// resolve it) instead. A `CREATE` is an ordinary statement here, not a
  /// special case; the shell prints whatever rows come back.
  ///
  /// `bindings` resolve a `:name` parameter of a `SELECT` or a `WITH` — the
  /// shell threads its `.bind` bindings through here, so a parameterized query
  /// typed at the prompt finds its values, whether the parameter sits in a
  /// plain `SELECT` or in a `WITH`'s body or trailing query. A `CREATE VIEW`
  /// ignores
  /// them: it stores the view's text, binding only when a later `SELECT` reads
  /// it.
  package mutating func run(_ statement: String, bindings: Bindings = [:])
      throws -> Array<Array<Value>> {
    let parsed = try Statement(parsing: statement)
    switch parsed {
    case let .create(name, view):
      register(name, view)
      return []
    case let .function(name, function):
      try register(name, function)
      return []
    case let .select(query):
      return try self.run(query, functions, bindings: bindings)
    case .with:
      return try self.run(parsed, functions, bindings: bindings)
    }
  }
}

// MARK: - Bundled views

extension Session {
  /// The session's built-in views, keyed case-folded — the union of the bundled
  /// query resources and any a `-I` search directory adds, each parsed the way
  /// a `CREATE VIEW` line registers, so a test (or the session's seed) can
  /// build the dictionary without driving the shell.
  ///
  /// This is the general seed operation: gather the view names from the bundled
  /// query set (`Resources/Queries/*.sql`) and every search directory's
  /// `Queries/*.sql`, then for each name load the first search directory that
  /// has it (else the bundle), parse it as a `CREATE VIEW`, and register it —
  /// so a `-I` directory both shadows an existing view and adds a new one. The
  /// COM-interface views are the one bundled set, so adding a query later is
  /// dropping in another `.sql` beside them (or under a `-I` directory) — no
  /// code change. The views are order-independent (none references another), so
  /// the enumeration order does not matter.
  ///
  /// These views denormalise a COM interface for rendering: an `interfaces`
  /// view that navigates each `TypeDef` to its `GuidAttribute` IID across the
  /// coded-index join keys — `TypeDef` ← `CustomAttribute.Parent_TypeDef`,
  /// then `CustomAttribute.Type_MemberRef` → `MemberRef`, then
  /// `MemberRef.Class_TypeRef` → `TypeRef`, filtered to the `GuidAttribute`
  /// declaring type, projecting `CustomAttribute.guid` as the `iid` — a
  /// `methods` view of one interface's methods, a `params` view of one
  /// method's parameters, a `bases` view of one interface's named base type,
  /// and a `generics` view of one interface's declared generic parameters.
  /// These carry a uniform `:parent` param — the owning row's `Id` — so a
  /// render can walk interface → methods → params, binding each level's `Id` to
  /// the next's `:parent`, and look up the interface's base by its `Id`.
  ///
  /// The `bases` view navigates the interface's single `InterfaceImpl` row
  /// (whose simple `Class` index is the interface's 1-based `Id`) to its
  /// base type's simple name, projecting `TypeRef.TypeName` as `base`. The
  /// `Class` column is a *simple* `TypeDef` index — it stores the `Id`
  /// directly, so the predicate is `i.Class = :parent` (there is no decoded
  /// `Class_TypeDef` join key — `WinMDRelation.keys` derives keys only for
  /// *coded* indices). `Interface` is the coded `TypeDefOrRef`, so its decoded
  /// `Interface_TypeRef` key equi-joins the base `TypeRef`. Both arms of the
  /// coded index resolve, `UNION`ed: a cross-file base through
  /// `Interface_TypeRef` (a `TypeRef`) and a same-file base through
  /// `Interface_TypeDef` (a `TypeDef` in this module).
  ///
  /// A query resource is static, well-formed SQL, so a parse failure is a
  /// programming error rather than user input; it is silently skipped here (the
  /// view simply does not register).
  internal static func bundled(search: Array<String> = [])
      -> Dictionary<String, View> {
    // The view names to seed: those bundled, plus any a search directory adds.
    var names = Set<String>()
    for url in Bundle.module.urls(forResourcesWithExtension: "sql",
                                  subdirectory: "Resources/Queries") ?? [] {
      // `urls(forResourcesWithExtension:)` vends `NSURL` on non-Darwin
      // Foundation, whose path API differs; bridge it to `URL`.
      names.insert((url as URL).deletingPathExtension().lastPathComponent)
    }
    for directory in search {
      let path = "\(directory)/Queries"
      let files =
          (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
      for file in files where file.hasSuffix(".sql") {
        names.insert(String(file.dropLast(4)))
      }
    }
    // Each name loads from the first search dir that has it, else the bundle.
    var views = Dictionary<String, View>()
    for name in names {
      guard let url = resource(name, "sql", kind: "Queries", search: search),
            let data = try? Data(contentsOf: url) else { continue }
      let text = String(decoding: data, as: UTF8.self).trimmed.statement
      if case let .create(view, definition)? = try? Statement(parsing: text) {
        views[view.lowercased()] = definition
      }
    }
    return views
  }
}

/// Locates the bundled query resource `<name>.sql` of the given `kind`
/// (`Queries`), preferring a user override: the search directories are tried
/// last-first as `<dir>/<kind>/<name>.<ext>` (so a later `-I` wins over an
/// earlier one), then the package bundle's `Resources/<kind>/<name>.<ext>`.
/// `nil` when none has it.
private func resource(_ name: String, _ ext: String, kind: String,
                      search: Array<String>) -> URL? {
  for directory in search.reversed() {
    let path = "\(directory)/\(kind)/\(name).\(ext)"
    if FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
  }
  return Bundle.module.url(forResource: name, withExtension: ext,
                           subdirectory: "Resources/\(kind)")
}

// MARK: - Helpers

extension StringProtocol {
  /// This text with leading and trailing whitespace removed — a stdlib-only
  /// trim (no Foundation `CharacterSet`).
  package var trimmed: String {
    String(drop { $0.isWhitespace }.reversed()
               .drop { $0.isWhitespace }.reversed())
  }

  /// This statement with a single trailing `;` removed — the trailing `;` a
  /// query statement may carry is optional.
  package var statement: String {
    hasSuffix(";") ? String(dropLast()) : String(self)
  }
}

extension Value {
  /// This cell's `text`, the empty string for any non-text cell — the render
  /// only ever reads `.text` columns (names, types, the IID), so a non-text
  /// cell is a NULL the caller has already filtered.
  package var text: String {
    if case let .text(text) = self { text } else { "" }
  }

  /// This cell's `integer`, zero for any non-integer cell — the render reads a
  /// `Id`/`Sequence` `.integer` column to navigate a signature, so a
  /// non-integer cell is a NULL the query guarantees never appears there.
  package var integer: Int {
    if case let .integer(integer) = self { integer } else { 0 }
  }
}
