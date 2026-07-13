// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The relations in scope, keyed case-folded — the materialised relations the
/// engine resolves a query's `FROM`/`JOIN` names against, consulted before the
/// base catalog (a bound name shadows a base table or view of the same name).
///
/// It is threaded alongside the borrowed base catalog through every resolution
/// phase: when the engine resolves a relation name, it consults
/// `ScopedRelations` first, and a bound leaf materialises its records from the
/// `RelationInstance` rows rather than opening a base cursor. An empty
/// `ScopedRelations` is the default — a query with no `WITH` and no derived
/// table resolves exactly as before. Threading escapable data sidesteps
/// wrapping the borrowed `~Escapable` base catalog in a unifying overlay type.
///
/// It is a NON-DESTRUCTIVE LAYERED scope, not a flat map. The overlay is a
/// stack of layers: a `base` layer holds the statement-scoped bindings — every
/// common table expression a `WITH` materialises and every store relation a
/// query names — and each `augment` for a SELECT PUSHES a derived layer holding
/// that SELECT's own `FROM (SELECT …) AS t` derived aliases. A name resolves
/// against the INNERMOST layer that binds it, so a derived alias `t` SHADOWS a
/// same-named CTE `t` in the base layer WITHOUT deleting it — `reveal` drops
/// the derived layers and the CTE beneath is resolved again. This makes the
/// CTE-overwrite class impossible: a nested subquery's FROM, a lazy scalar, and
/// a set-op arm each resolve against the REVEALED base rather than a
/// separately-threaded pre-augment context.
internal struct ScopedRelations: Hashable, Sendable,
                                 ExpressibleByDictionaryLiteral {
  /// The statement-scoped bindings — every common table expression and
  /// `definition_schema.` store relation in scope (`derivation == nil`). It is
  /// what a nested subquery's FROM and a revealed body resolve against: a CTE
  /// is statement-scoped, visible under any number of enclosing derived layers.
  private var base: Dictionary<String, RelationInstance>

  /// The stack of SELECT-scoped derived layers, outermost first. Each
  /// `augment` for a SELECT with `FROM (SELECT …) AS t` derived tables pushes
  /// one layer binding that SELECT's own aliases; a name resolves against the
  /// innermost (last) layer that binds it, so an inner derived alias shadows an
  /// outer same-named one and both shadow the base. Empty for a query with no
  /// derived table.
  private var layers: Array<Dictionary<String, RelationInstance>>

  /// An empty overlay — the scope a bare query with no `WITH` and no derived
  /// table runs under.
  internal init() {
    self.base = [:]
    self.layers = []
  }

  internal init(dictionaryLiteral elements: (String, RelationInstance)...) {
    self.base = Dictionary(uniqueKeysWithValues: elements)
    self.layers = []
  }

  /// The binding `name` resolves to — the innermost derived layer that holds
  /// it, else the base layer — or `nil` when no layer binds it. Setting binds
  /// `name` in the INNERMOST layer (the current derived layer, else the base),
  /// shadowing an outer same-named binding without deleting it; setting `nil`
  /// removes it from that layer only.
  internal subscript(name: String) -> RelationInstance? {
    get {
      for layer in layers.reversed() {
        if let materialised = layer[name] { return materialised }
      }
      return base[name]
    }
    set {
      if layers.isEmpty {
        base[name] = newValue
      } else {
        layers[layers.count - 1][name] = newValue
      }
    }
  }

  /// This overlay with `derivations` PUSHED as a new derived layer — the scope
  /// a SELECT resolves its own FROM/JOIN and expressions against, each derived
  /// alias shadowing an outer same-named CTE or derived alias without deleting
  /// it. It is idempotent on the layer's IDENTITY: pushing a layer whose
  /// aliases and derivation queries EQUAL the innermost derived layer's (the
  /// run→compile→typecheck chain re-augments the same query) is a no-op, so
  /// the stack stays bounded and a self-named alias's body still reads the
  /// base.
  internal func pushing(_ derivations: Dictionary<String, RelationInstance>)
      -> ScopedRelations {
    guard !derivations.isEmpty else { return self }
    if layers.last == derivations { return self }
    var copy = self
    copy.layers.append(derivations)
    return copy
  }

  /// This overlay with every derived layer DROPPED, leaving the base layer —
  /// the scope a NESTED subquery's FROM resolves against. A derived alias is
  /// SELECT-scoped: it names a relation only in its OWN SELECT's FROM/JOIN and
  /// expressions, invisible to a nested subquery's FROM exactly as a base-table
  /// alias in the enclosing FROM is. A CTE, by contrast, is statement-scoped
  /// — visible inside a nested subquery's FROM — so the base layer stays,
  /// REVEALING any CTE a dropped derived alias shadowed.
  internal func revealed() -> ScopedRelations {
    var copy = self
    copy.layers = []
    return copy
  }

  /// The derivation query bound for `name` in the innermost derived layer that
  /// holds it, else `nil` — the identity `augment` keys its per-alias
  /// idempotence on (a binding whose `derivation` EQUALS the inner query is
  /// this SELECT's own prior pass, left rather than re-derived).
  internal func derivation(of name: String) -> Query? {
    for layer in layers.reversed() {
      if let materialised = layer[name] { return materialised.derivation }
    }
    return nil
  }

  /// Whether NO layer binds any name — an untouched overlay. The lazy-scalar
  /// path reads it to tell a cache carrying this occurrence's pre-augment scope
  /// from a bare one (a schema path's `Subqueries`), falling back to the
  /// threaded overlay for the latter.
  internal var isEmpty: Bool {
    base.isEmpty && layers.allSatisfy(\.isEmpty)
  }
}

/// An escapable, in-engine relation over `(columns, rows)`.
///
/// A `RelationInstance` is fully owned data — a common table expression's
/// query run to a fixed set of rows, named by its columns — that the engine
/// resolves a CTE name to. It is escapable, so it sits beside the `~Escapable`
/// base catalog without the lifetime machinery a borrowed source needs: the
/// engine threads a `Dictionary<String, RelationInstance>` of the in-scope
/// CTEs alongside the borrowed base catalog, consulting it first when it
/// resolves a name, and builds the leaf records directly from `rows` rather
/// than opening a cursor.
///
/// It exposes the universal `Id` virtual column at `width`, so a CTE
/// resolves columns exactly as a base relation does (a real column below
/// `width`, the `Id` at `width`).
internal struct RelationInstance: Hashable, Sendable {
  /// The relation's column names, in ordinal order.
  internal let columns: Array<String>

  /// The relation's rows, each a positional array of typed values.
  internal let rows: Array<Array<Value>>

  /// The value type of each real column, in ordinal order — the types a
  /// materialised relation reports to the result-schema walk.
  ///
  /// A CTE's rows carry no static types, so its call site types every column
  /// `.integer` (the same default a view without a typed schema advertises); a
  /// DEFINITION_SCHEMA store relation, whose columns have known ISO domains,
  /// passes them so `information_schema` columns report their real types.
  internal let types: Array<ValueType>

  /// The inner `Query` this binding is the materialised body of, when it is a
  /// DERIVED TABLE's — `nil` for a common table expression's or a store
  /// relation's binding. It is the derivation's IDENTITY, not merely a flag:
  /// `augment` keys idempotence on it, so it can tell THIS query's own prior
  /// materialisation of an alias (the run→compile double augment, or a
  /// self-named `(SELECT … FROM T) AS T`) apart from an ENCLOSING query's
  /// same-named derived binding.
  ///
  /// `augment` reads it two ways. Dropping the enclosing scope's derived
  /// bindings (any non-`nil` `derivation`) before resolving a body is what lets
  /// a self-named `(SELECT … FROM T) AS T` read the base `T` while KEEPING a
  /// same-named CTE in scope (so `WITH t … FROM (SELECT … FROM t) AS t`
  /// resolves the CTE). And a binding whose `derivation` EQUALS the inner query
  /// being materialised is this query's own prior pass, left as materialised
  /// rather than re-derived (idempotent); a binding whose `derivation` differs
  /// — or is `nil` — is an enclosing query's, and this query's alias
  /// re-materialises over it, SHADOWING it.
  internal let derivation: Query?

  /// Whether this binding is a DERIVED TABLE's materialised body — as opposed
  /// to a common table expression's or a store relation's.
  internal var derived: Bool { derivation != nil }

  internal init(columns: Array<String>, rows: Array<Array<Value>>,
                types: Array<ValueType>, derivation: Query? = nil) {
    self.columns = columns
    self.rows = rows
    self.types = types
    self.derivation = derivation
  }

  /// The real column count — the extent of a `SELECT *`.
  internal var width: Int { columns.count }

  /// One past the highest ordinal — the real width plus the lone virtual
  /// `Id` column at `width`.
  internal var extent: Int { width + 1 }

  /// The resolution schema of this relation: its columns below `width`, a
  /// virtual `Id` at `width`.
  internal func schema() -> Schema {
    Schema(width: width, extent: extent, names: columns,
           types: types, virtuals: ["Id"])
  }

  /// The record for the row at `index`, materialising the referenced `ordinals`
  /// into dense slots — a real ordinal (`< width`) reads the stored cell, the
  /// virtual `Id` ordinal (`== width`) the 1-based row index.
  internal func record(_ index: Int, _ ordinals: Array<Int>) -> Record {
    let cells = rows[index]
    return Record(ordinals.map {
      $0 == width ? .integer(index + 1) : cells[$0]
    })
  }
}
