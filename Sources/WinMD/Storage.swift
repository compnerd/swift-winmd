// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A borrowed, ARC-free projection of a database's readable state.
///
/// `Database` owns `relations: Array<Table>`, the one ARC-bearing type in the
/// library. The row cursors only ever read out of the backing buffer and the
/// open tables, so rather than carry the whole `Database` — which would retain
/// and release the relations buffer on every cursor copy — they carry this
/// trivial view: a `Span<Table>` into the relations plus the read spans. The
/// existing `~Escapable` lifetime dependency keeps it sound.
///
/// The type is `public` — it is the readable handle a caller opens a
/// `SQLEngineWinMD.WinMDDatabase` over — while the byte-level members the query
/// scan reads stay `package`, reached by the SQL-engine adapter that conforms
/// it to the engine's `Catalog` across the module boundary. A caller obtains
/// one from a mapped file through `Database.storage`, not by assembling it.
public struct Storage: ~Escapable {
  /// The backing buffer.
  internal let bytes: RawSpan

  /// The open tables of the database, borrowed from `Database.relations`.
  package let tables: Span<Table>

  /// The "Strings" (`#Strings`) heap.
  internal let strings: RawSpan

  /// The "Blob" (`#Blob`) heap.
  internal let blob: RawSpan

  /// The "GUID" (`#GUID`) heap.
  internal let guid: RawSpan

  /// The bitset of present tables (`TablesStream.Valid`).
  internal let valid: UInt64

  /// The bitset of physically sorted tables (`TablesStream.Sorted`).
  ///
  /// Bit `N` is set iff table `N` is stored ordered by its sort key. A reverse
  /// foreign-key lookup against a sorted table is a binary search; against an
  /// unsorted one it is a linear scan.
  package let sorted: UInt64

  @_lifetime(copy bytes, copy relations, copy strings, copy blob, copy guid)
  internal init(bytes: RawSpan, relations: Span<Table>, strings: RawSpan,
                blob: RawSpan, guid: RawSpan, valid: UInt64, sorted: UInt64) {
    self.bytes = bytes
    self.tables = relations
    self.strings = strings
    self.blob = blob
    self.guid = guid
    self.valid = valid
    self.sorted = sorted
  }

  @_lifetime(copy self)
  internal func rows<Schema: TableSchema>(of schema: Schema.Type,
                                          from begin: Int = 0,
                                          to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Schema> {
    // `tables` is dense and ordered by table number, so a present table's
    // slot is the number of present tables below it: the population count of
    // the lower bits of `Valid` (the same slot the row counts are read from).
    if valid & (1 << Schema.number) == 0 {
      throw .TableNotFound
    }
    let slot = (valid & ((1 << Schema.number) - 1)).nonzeroBitCount
    return TableIterator<Schema>(self, tables[slot], from: begin, to: end)
  }

  /// The `Tuple` at the 0-based `row` of the table described by `schema`.
  ///
  /// This is the runtime (non-generic) sibling of `rows(of:)`: it opens a table
  /// from a `TableSchema.Type` *value* rather than a static `Schema`, which is
  /// what foreign-key navigation needs — the target table of an index is only
  /// known at runtime, off the column's `Index`. The present table's slot is
  /// found by the same population-count math as `rows(of:)`, off `schema.number`
  /// read from the metatype. `row` is bounds-checked against the table's row
  /// count; an absent table or an out-of-range row yields `nil`.
  @_lifetime(copy self)
  internal func tuple(_ row: Int, of schema: TableSchema.Type)
      throws(WinMDError) -> Tuple? {
    if valid & (1 << schema.number) == 0 { return nil }
    let slot = (valid & ((1 << schema.number) - 1)).nonzeroBitCount
    let table = tables[slot]
    guard row >= 0, row < Int(table.rows) else { return nil }
    return Tuple(row, table, self)
  }

  /// The row a `TypeDefOrRef` coded index references, or `nil` if it is null.
  ///
  /// The storage-level sibling of `Database.resolve`: the index's tag selects
  /// `TypeDef`/`TypeRef`/`TypeSpec` and its row is 1-based, so this opens the
  /// named table at `row - 1`. A null reference (`row == 0`) yields `nil`. It is
  /// `package` so the `WinMDSynthesis` decode helper resolves the references a
  /// signature names against a borrowed `Storage` rather than a `Database`.
  @_lifetime(copy self)
  package func resolve(_ reference: TypeDefOrRef) throws(WinMDError) -> Tuple? {
    if reference.row == 0 { return nil }
    guard reference.tag < TypeDefOrRef.tables.count,
        let schema = TypeDefOrRef.tables[reference.tag] else {
      throw .BadImageFormat
    }
    guard let tuple = try tuple(reference.row - 1, of: schema) else {
      throw .BadImageFormat
    }
    return tuple
  }

  /// The rows of `schema` whose foreign-key `column` references `target`.
  ///
  /// The runtime (non-generic) sibling of `Database.referencing`: it opens the
  /// owning table from a `TableSchema.Type` value, computes the encoded key an
  /// owning row would hold to point at `target`, and returns the matching rows.
  /// The cost is `O(log n)` when the table is sorted on `column` and `O(rows)`
  /// otherwise; see `Database.referencing` for the encoding and the contract.
  @_lifetime(copy self)
  internal func referencing(_ target: borrowing Tuple,
                            in schema: TableSchema.Type,
                            by column: Int)
      throws(WinMDError) -> Filter<Cursor> {
    if valid & (1 << schema.number) == 0 {
      throw .TableNotFound
    }
    let slot = (valid & ((1 << schema.number) - 1)).nonzeroBitCount
    let table = tables[slot]

    // The stored cell an owning row holds to name `target`. ECMA-335 rows are
    // 1-based, so `target`'s 0-based row is stored as `target.row + 1`.
    let row = target.row + 1
    guard column >= 0, column < schema.fields.count else { throw .InvalidColumn }
    let encoded: Int = switch schema.fields[column].type {
    case let .index(.simple(referent)):
      // A simple index must name `target`'s own table.
      if referent == target.table.schema {
        row
      } else {
        throw .InvalidColumn
      }
    case let .index(.coded(coded)):
      // A coded index tags the row with the position of `target`'s table among
      // the index's tables: `(row << bits) | tag`.
      if let tag = tag(of: target.table.schema, in: coded) {
        (row << coded.bits) | tag
      } else {
        throw .InvalidColumn
      }
    default:
      throw .InvalidColumn
    }

    // A table physically sorted on this very column holds its matches as a
    // contiguous run; binary-search the `[lower, upper)` bound of `encoded`.
    if schema.key == column, sorted & (1 << schema.number) != 0 {
      let count = Int(table.rows)
      let lower = bound(table, column, encoded, count, strict: false)
      let upper = bound(table, column, encoded, count, strict: true)
      let cursor = Cursor(self, table, from: lower, to: upper)
      return Filter(cursor, { _ in true })
    }

    // Otherwise scan, matching the raw cell against the encoded key.
    let cursor = Cursor(self, table)
    return cursor.where { $0[column] == encoded }
  }

  /// The rows whose simple-index foreign-key column the `column` token
  /// addresses references `target`.
  ///
  /// Typed reverse navigation: the `Reference` token names the owning `Owner`
  /// table and the column's ordinal, so this resolves to the generic
  /// `referencing(_:in:by:)` with no string or ordinal at the call site.
  @_lifetime(copy self)
  internal func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                           by column: Reference<Owner, Target>)
      throws(WinMDError) -> Filter<Cursor> {
    try referencing(target.columns, in: Owner.self, by: column.ordinal)
  }

  /// The rows whose coded-index foreign-key column the `column` token addresses
  /// references `target`.
  @_lifetime(copy self)
  internal func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                           by column: CodedReference<Owner>)
      throws(WinMDError) -> Filter<Cursor> {
    try referencing(target.columns, in: Owner.self, by: column.ordinal)
  }

  /// The partition point of `column` against `value` over `[0, count)`.
  ///
  /// `column` is the sorted key of `table`, so its cells are non-decreasing.
  /// With `strict == false` this is the lower bound (the first row whose cell is
  /// `>= value`); with `strict == true` the upper bound (the first row whose
  /// cell is `> value`). Together they bracket the run equal to `value`. The
  /// search is `O(log count)`. Shared by the reverse-foreign-key lookup, the
  /// structured-query sorted-index executor (`Cursor.where(_: Predicate)`), and
  /// the SQL-engine adapter's seekable-column `bound`.
  package func bound(_ table: Table, _ column: Int, _ value: Int, _ count: Int,
                     strict: Bool) -> Int {
    var lo = 0
    var hi = count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      let cell = Tuple(mid, table, self)[column]
      if cell < value || (strict && cell == value) {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    return lo
  }

  /// The tag of `schema` within the tables of `coded`, or `nil` if absent.
  ///
  /// The tag is the position of the table in the coded index's table list,
  /// found by a linear metatype comparison (`Span` admits no `firstIndex`).
  private func tag(of schema: TableSchema.Type,
                   in coded: CodedIndex.Type) -> Int? {
    for index in 0 ..< coded.tables.count {
      if let table = coded.tables[index], table == schema {
        return index
      }
    }
    return nil
  }

  // MARK: - Nesting

  /// The lexically enclosing type of the type `tuple` names — its immediate
  /// encloser — or `nil` when the type is top-level.
  ///
  /// A `TypeRef` nests through its `ResolutionScope`: a scope that is itself a
  /// `TypeRef` is the enclosing reference, and any other scope (a `Module`, a
  /// `ModuleRef`, or an `AssemblyRef`) makes the reference top-level. A
  /// `TypeDef` nests through the `NestedClass` table (§II.22.32) — the
  /// `EnclosingClass` of the row whose `NestedClass` names this definition,
  /// found by binary search when the table is stored sorted on its key and by a
  /// linear scan otherwise. Any other table has no enclosing and yields `nil`.
  /// It is `package` so the synthesis decode and the render adapter compose one
  /// nested type's dot-path from the same walk.
  @_lifetime(copy self)
  package func enclosing(_ tuple: borrowing Tuple)
      throws(WinMDError) -> Tuple? {
    // The enclosing tuple is opened off `self` (not off the borrowed `tuple`)
    // so its lifetime tracks the storage rather than the shorter-lived
    // argument, which is what a recursive walk returns through.
    switch tuple.table.number {
    case Metadata.Tables.TypeRef.number:
      guard let scope = tuple.ordinal(for: "ResolutionScope") else {
        return nil
      }
      // Tag 3 of `ResolutionScope` selects `TypeRef`: a scope that is itself a
      // `TypeRef` is the enclosing reference; a `Module`/`ModuleRef`/
      // `AssemblyRef` scope makes the reference top-level.
      let coded = ResolutionScope(rawValue: tuple[scope])
      guard coded.tag == 3, coded.row != 0 else { return nil }
      return try self.tuple(coded.row - 1,
                            of: Metadata.Tables.TypeRef.self)
    case Metadata.Tables.TypeDef.number:
      guard let table = opened(Metadata.Tables.NestedClass.number) else {
        return nil
      }
      // The `NestedClass` (ordinal 0) column holds the 1-based `TypeDef` Id of
      // the nested type; `EnclosingClass` (ordinal 1) its encloser.
      let child = tuple.row + 1
      let count = Int(table.rows)
      if sorted & (1 << Metadata.Tables.NestedClass.number) != 0 {
        let lower = bound(table, 0, child, count, strict: false)
        guard lower < count, Tuple(lower, table, self)[0] == child else {
          return nil
        }
        return try self.tuple(Tuple(lower, table, self)[1] - 1,
                              of: Metadata.Tables.TypeDef.self)
      }
      for index in 0 ..< count where Tuple(index, table, self)[0] == child {
        return try self.tuple(Tuple(index, table, self)[1] - 1,
                              of: Metadata.Tables.TypeDef.self)
      }
      return nil
    default:
      return nil
    }
  }

  /// The dot-path name of the type `tuple` names, from its outermost encloser —
  /// `Foo.Bar` for a `Bar` nested under `Foo`, `Foo.Bar.Baz` for a deeper
  /// nesting — or the bare `TypeName` for a top-level type.
  ///
  /// The components are joined raw (unescaped); a caller that spells the path
  /// as target source escapes each component separately, so a keyword component
  /// is delimited within the path rather than treated as one identifier.
  package func qualified(_ tuple: borrowing Tuple)
      throws(WinMDError) -> String {
    // Each component is a declaration name spelled arity-stripped: a generic
    // encloser `Outer``1` nests as `Outer` and the generic decode strips the
    // leaf, so strip every component of the enclosing path here — a signature
    // spelling `Outer.Inner`, not the unresolved `Outer``1.Inner`. The suffix
    // marks only a generic definition, which is never a `known` bridge or
    // `System.Guid` (both non-generic), so the identity this feeds still
    // matches those lookups, and a top-level component is already projected at
    // the seam that qualifies it.
    let name = try projected(bare(tuple))
    guard let outer = try enclosing(tuple) else { return name }
    return try qualified(outer) + "." + name
  }

  /// As `qualified`, but the *leaf* component keeps its CLR generic-arity
  /// suffix (`` Box`1 ``) while the enclosing path stays arity-stripped. The
  /// decode's well-known lookup keys on this raw leaf — the spec maps a
  /// generic type by its raw name (`Box1`) — while the projected spelling still
  /// strips the suffix, so the two agree on a non-generic type and diverge only
  /// where a generic's arity is the difference between hitting and missing the
  /// configured bridge.
  package func identifier(_ tuple: borrowing Tuple)
      throws(WinMDError) -> String {
    let leaf = try bare(tuple)
    guard let outer = try enclosing(tuple) else { return leaf }
    return try qualified(outer) + "." + leaf
  }

  /// Whether any *enclosing* type of `tuple` is generic — its raw `TypeName`
  /// carries the CLR arity suffix (a backtick). Such a nesting has no valid
  /// unqualified spelling: a member of `Outer``1` is `Outer<T>.Inner`, which
  /// needs the enclosing specialization, while both `qualified`'s arity-stripped
  /// `Outer.Inner` and appending the generic arguments to the leaf misname it.
  /// Projecting the WinRT generic-nesting specialization is a deferred redesign,
  /// so a reference into such a type is an unsupported frontier the caller drops
  /// rather than spelling. Only an *encloser*'s arity matters: the leaf's own
  /// generic arity is stripped and supplied by the decode's own clause.
  package func enclosedByGeneric(_ tuple: borrowing Tuple)
      throws(WinMDError) -> Bool {
    guard let outer = try enclosing(tuple) else { return false }
    if try bare(outer).contains("`") { return true }
    return try enclosedByGeneric(outer)
  }

  /// Whether the `TypeDef` at 1-based `id` is nested under a generic encloser —
  /// the `enclosedByGeneric` test addressed by a resolved local `Id` and not a
  /// `Tuple`, for a caller that holds only the Id the reference resolved to.
  /// A missing row is not nested.
  package func enclosedByGeneric(of id: Int) throws(WinMDError) -> Bool {
    guard let tuple = try self.tuple(id - 1, of: Metadata.Tables.TypeDef.self)
    else {
      return false
    }
    return try enclosedByGeneric(tuple)
  }

  /// The dot-path name of the `TypeDef` at 1-based `id` — the `qualified`
  /// spelling addressed by `Id` rather than by an already-fetched `Tuple`, for
  /// a caller (the render's inheritance clause) that holds only the resolved
  /// base `Id`. A missing row spells empty, the same absent-name the caller's
  /// bare fallback would.
  package func qualified(of id: Int) throws(WinMDError) -> String {
    guard let tuple = try self.tuple(id - 1, of: Metadata.Tables.TypeDef.self)
    else {
      return ""
    }
    return try qualified(tuple)
  }

  /// The enclosing `TypeDef` chain of the `TypeDef` at 1-based `id`, outermost
  /// first — each an `(id, name)` pair — for the render to group a nested type
  /// under a container per level. An empty array for a top-level type.
  package func nesting(of id: Int)
      throws(WinMDError) -> Array<(id: Int, name: String)> {
    guard let tuple = try self.tuple(id - 1, of: Metadata.Tables.TypeDef.self),
        let outer = try enclosing(tuple) else {
      return []
    }
    return try nesting(of: outer.row + 1) + [(outer.row + 1, bare(outer))]
  }

  // MARK: - Kind and qualification

  /// The projection kind of a named type — how the render spells and nests it.
  ///
  /// The partition is the one the SQL `types` view draws: an `interface` (the
  /// `tdInterface` flag), a `delegate`/`structure`/`enumeration` (told apart by
  /// the base its `Extends` names — `System.MulticastDelegate`/`System.ValueType`
  /// /`System.Enum`), or a runtime `class` (anything else). Only a `structure`
  /// or `enumeration` is a value type, spelled fully namespace-qualified and
  /// nested; the rest spell by their bare name.
  package enum Kind: Sendable, Equatable {
    case interface
    case delegate
    case structure
    case enumeration
    case `class`

    /// Whether the kind is a value type — a `structure` or an `enumeration` —
    /// the render namespace-qualifies and nests, as opposed to a `protocol`
    /// (`interface`/`delegate`) or a runtime `class` it spells bare.
    package var value: Bool {
      self == .structure || self == .enumeration
    }
  }

  /// The projection kind of the `TypeDef` the `tuple` names, classified exactly
  /// as the SQL `types` view does so the decode spelling and the emit nesting
  /// agree from one source.
  ///
  /// The `tdInterface` flag (`0x20`) marks an interface regardless of its base;
  /// otherwise the base type the `Extends` coded index names classifies the row
  /// — `System.Enum` an enumeration, `System.MulticastDelegate` a delegate,
  /// `System.ValueType` a structure, anything else (or no base) a runtime class.
  package func kind(_ tuple: borrowing Tuple) throws(WinMDError) -> Kind {
    if let flags = tuple.ordinal(for: "Flags"), tuple[flags] & 0x20 == 0x20 {
      return .interface
    }
    guard let extends = tuple.ordinal(for: "Extends") else { return .class }
    let base = TypeDefOrRef(rawValue: tuple[extends])
    guard let parent = try resolve(base) else { return .class }
    switch try names(parent) {
    case ("System", "Enum"):              return .enumeration
    case ("System", "MulticastDelegate"): return .delegate
    case ("System", "ValueType"):         return .structure
    default:                              return .class
    }
  }

  /// The CLR namespace the value type at 1-based `id` nests under — the
  /// namespace segments its fully-qualified spelling and its fabricated
  /// namespace `enum` containers share.
  ///
  /// A nested type carries an empty `TypeNamespace`; the CLR namespace lives on
  /// its outermost encloser, so the walk climbs the enclosing chain to that
  /// outermost `TypeDef` and reads its namespace. A top-level type is its own
  /// outermost, so this reads its own namespace. The empty string is the global
  /// namespace, which fabricates no container.
  package func namespace(of id: Int) throws(WinMDError) -> String {
    let chain = try nesting(of: id)
    let outermost = chain.first?.id ?? id
    guard let tuple = try self.tuple(outermost - 1,
                                     of: Metadata.Tables.TypeDef.self),
        let space = tuple.ordinal(for: "TypeNamespace") else {
      return ""
    }
    return try tuple.string(space)
  }

  /// The namespace-qualified render spelling of the named type `reference`
  /// names, or `nil` when it spells by its bare (or enclosing) name — the
  /// fallback a caller already applies for an unresolvable reference or a
  /// non-ambiguous type.
  ///
  /// Qualification is collision-only: a value type spells its full CLR
  /// namespace, enclosing-`TypeDef` dot-path, and own name
  /// (`Windows.Win32.Foundation.Point`, `A.B.Outer.Inner`) — matching the
  /// fabricated namespace `enum` and real container nesting the emit builds —
  /// only when its simple `TypeName` is ambiguous, which the caller-supplied
  /// `qualifying` set names (see `collisions()`).
  ///
  /// Qualification is applied to a value-type *identity*, not to a bare name:
  /// only a value type is ever wrapped in a namespace container, so a reference
  /// that shares the ambiguous name yet names an interface/delegate (a bare
  /// `protocol`), a runtime `class`, or an external type (the consumer supplies
  /// it bare) yields `nil` and keeps its bare name — else it would spell
  /// `NS.Point` for a type no `NS.Point` declaration is emitted for. So it gates
  /// on the reference's full `namespace.name`: `collisions()` records that
  /// identity only for an ambiguous *value* type, so a same-named non-value
  /// reference's identity is simply absent and the reference spells bare — with
  /// no per-reference resolution.
  ///
  /// The bare-name membership test is the fast path, applied *before* forming the
  /// identity: a reference whose bare (or outermost) name is not ambiguous
  /// returns `nil` at once. The components join raw; a caller escapes each
  /// separately.
  package func spelling(of reference: TypeDefOrRef, qualifying: Set<String>)
      throws(WinMDError) -> String? {
    guard let resolved = try resolve(reference) else { return nil }
    return try spelling(resolved: resolved, qualifying: qualifying,
                        local: try local(reference))
  }

  /// The qualified spelling of the local `TypeDef` at 1-based `id` under the
  /// `qualifying` set — the inheritance-clause counterpart of `spelling(of
  /// reference:qualifying:)`, sharing its one qualification rule so an
  /// interface's base spells exactly as a signature naming the same type
  /// decodes. A nested base whose outermost encloser is a wrapped ambiguous
  /// value type reads `A.Outer.IChild`, not the bare enclosing `Outer.IChild`
  /// that fails to resolve. `nil` when the base is not qualified (its bare or
  /// enclosing spelling stands). A `TypeDef` is by definition local.
  package func spelling(of id: Int, qualifying: Set<String>)
      throws(WinMDError) -> String? {
    guard let tuple = try self.tuple(id - 1, of: Metadata.Tables.TypeDef.self)
    else {
      return nil
    }
    return try spelling(resolved: tuple, qualifying: qualifying, local: true)
  }

  /// The shared qualification core of both `spelling` overloads: given a
  /// resolved type row and whether it is local, the namespace-qualified
  /// spelling `qualifying` calls for, or `nil` when the type is not qualified.
  private func spelling(resolved: borrowing Tuple, qualifying: Set<String>,
                        local: Bool) throws(WinMDError) -> String? {
    let (space, raw) = try names(resolved)
    // The projected (arity-stripped) name, so a generic reference tests and
    // spells the one name the emission carries — matching the collision tally.
    let name = projected(raw)
    // A top-level reference is its own outermost encloser: its own CLR namespace
    // and name spell it, read straight off the resolved row — the fast path,
    // with no enclosing walk. (A Module-scoped `TypeRef` shares its target's
    // `(namespace, name)`, so the spelling agrees with the emit.) The bare name
    // fast-rejects; the `namespace.rawName` identity confirms a value type of
    // that *raw* name is ambiguous — keyed on the raw name, not the projected
    // one, so a same-namespace generic protocol whose raw name carries an arity
    // suffix does not borrow the value type's wrap; and `local` — following the
    // `ResolutionScope` — confirms *this* reference resolves to that local
    // definition, not an external `AssemblyRef`-scoped type of the same
    // identity (which the closure drops as nonlocal, and must not spell as the
    // wrapper).
    if !space.isEmpty {
      guard qualifying.contains(name),
          qualifying.contains(space + "." + raw),
          local else { return nil }
      return space + "." + name
    }
    // A nested (or global) reference carries an empty own namespace. It is
    // already disambiguated by its enclosing dot-path, so qualify only when its
    // outermost encloser's name is ambiguous — climbing the reference's own
    // enclosing chain (cheap along a `TypeRef` scope chain). The outermost's
    // namespace prefixes the reference's enclosing dot-path, and its
    // `namespace.rawName` identity confirms the outermost is a value type —
    // keyed on the raw name, so a same-named generic type does not borrow it.
    let outer = try outermost(resolved)
    let (root, outerRaw) = try names(outer)
    let outerName = projected(outerRaw)
    let identity = root.isEmpty ? outerRaw : root + "." + outerRaw
    guard qualifying.contains(outerName), qualifying.contains(identity),
        local else { return nil }
    let path = try qualified(resolved)
    return root.isEmpty ? path : root + "." + path
  }

  /// Whether `reference` resolves to a definition in this module — a `TypeDef`,
  /// or a `TypeRef` whose `ResolutionScope` chain terminates at the `Module`,
  /// not a `ModuleRef`/`AssemblyRef` (an external assembly). A qualified
  /// spelling is a local ambiguous value type's namespace path, so an external
  /// reference sharing that `(namespace, name)` — which the closure's SQL drops
  /// as nonlocal — must not take it, or the signature would bind the unrelated
  /// local wrapper (or an undefined name) instead of the consumer-supplied
  /// external type. This follows the scope chain only, not the `toplevel`/
  /// `nested` definition scan, so it confirms locality in O(depth) without the
  /// per-reference table walk.
  private func local(_ reference: TypeDefOrRef) throws(WinMDError) -> Bool {
    guard let tuple = try resolve(reference) else { return false }
    switch tuple.table.number {
    case Metadata.Tables.TypeDef.number:
      return true
    case Metadata.Tables.TypeRef.number:
      return try local(reference: tuple)
    default:
      return false
    }
  }

  /// Whether the `TypeRef` `tuple`'s `ResolutionScope` chain is local — a
  /// `TypeRef`-scoped (tag 3) nested reference whose enclosing reference is
  /// local, or a `Module`-scoped (tag 0) top-level reference. A `ModuleRef`/
  /// `AssemblyRef`, or a null scope, is external.
  private func local(reference tuple: borrowing Tuple)
      throws(WinMDError) -> Bool {
    guard let ordinal = tuple.ordinal(for: "ResolutionScope") else {
      return false
    }
    let scope = ResolutionScope(rawValue: tuple[ordinal])
    if scope.tag == 3, scope.row != 0 {
      guard let enclosing = try self.tuple(scope.row - 1,
                                           of: Metadata.Tables.TypeRef.self)
      else { return false }
      return try local(reference: enclosing)
    }
    return scope.tag == 0 && scope.row != 0
  }

  /// The outermost encloser of the type `tuple` names — the top of its nesting
  /// chain, itself when top-level — reached by climbing `enclosing`. The result
  /// is opened off `self`, so its lifetime tracks the storage.
  @_lifetime(copy self)
  private func outermost(_ tuple: borrowing Tuple)
      throws(WinMDError) -> Tuple {
    guard let up = try enclosing(tuple) else {
      return Tuple(tuple.row, tuple.table, self)
    }
    return try outermost(up)
  }

  /// The namespace-qualification sets a collision-only render keys off, computed
  /// in one scan so neither the decode nor the emit repeats the work per
  /// reference.
  ///
  /// The projection is one flat top-level Swift scope: an interface or delegate
  /// is a bare `protocol`, a runtime `class` and an external reference are bare
  /// frontiers the consumer supplies, and only a value type
  /// (`structure`/`enumeration`) can be wrapped — in a fabricated namespace
  /// `enum` — to disambiguate. A value type's simple `TypeName` is therefore
  /// ambiguous when two or more distinct top-level `TypeDef`s bear it *of any
  /// kind* — a second value type, an interface/delegate, or a runtime class —
  /// because spelled bare it would clash with that other top-level declaration.
  /// When it is, the value type — and any type nested under it — is spelled and
  /// emitted namespace-qualified, while the colliding protocol/class stays bare
  /// (a bare `protocol Point` and a wrapped `NS.Point` no longer clash).
  ///
  /// Only top-level definitions are counted: a nested type is already
  /// disambiguated by its enclosing-type dot-path (`Foo.Bar`) and never occupies
  /// the top-level scope, so qualification keys off the outermost encloser's
  /// name, which the nested count would only pollute. This also keeps the
  /// ubiquitous anonymous nested record names — Win32 gives every one the same
  /// generated `_Anonymous_e__…`, yet each is unique under its distinct
  /// encloser — out of the tally, so a nested record stays bare
  /// (`VARIANT._Anonymous_e__Struct`) rather than drowning the projection in
  /// namespace paths.
  ///
  /// The scan tallies every top-level `TypeDef` name and derives from a name's
  /// multiplicity:
  /// - `names`: the ambiguous top-level `TypeName`s, so the decode gates its
  ///   namespace-qualification on an O(1) membership test of a reference's own
  ///   (or outermost encloser's) name before it resolves the reference's kind;
  /// - `ids`: the ambiguous *value-type* `TypeDef` `Id`s alone — the only kind
  ///   the emit wraps in a namespace `enum` — so a colliding protocol or class,
  ///   which the emit leaves bare, is absent (a nested value type nests under
  ///   its encloser regardless).
  ///
  /// `reached`, when non-nil, restricts the tally to the `TypeDef` `Id`s in
  /// it — the declarations a `--closure` render actually emits — so a name is
  /// ambiguous only among the reached set. An unreachable definition never
  /// becomes a Swift declaration, so it cannot clash with one: leaving it out
  /// keeps a closure from wrapping (and possibly faulting) a value type on
  /// account of a same-named type the closure does not emit. A nil `reached`
  /// (the flat render, which emits the whole assembly) tallies every top-level
  /// `TypeDef`.
  ///
  /// `contended` names top-level types a `--closure` render spells but does not
  /// emit — a frontier such as an external or runtime-class `B.Point` a
  /// signature references. The `reached` tally sees only the emitted
  /// definitions, so a local value type `A.Point` reached alongside such a
  /// frontier reads as
  /// the sole bearer of `Point` and would spell bare, capturing the frontier's
  /// reference. A frontier is a distinct top-level type bearing that name, so a
  /// reached value type whose projected name is `contended` is bumped to
  /// ambiguous — wrapped and qualified — even when it is the only *emitted*
  /// bearer. A `contended` name no reached value type bears wraps nothing
  /// (there is no emitted definition to disambiguate).
  package func collisions(among reached: Set<Int>? = nil,
                          contended: Set<String> = [])
      throws(WinMDError) -> (names: Set<String>, ids: Set<Int>) {
    guard let table = opened(Metadata.Tables.TypeDef.number) else {
      return ([], [])
    }
    // The nested `TypeDef` Ids, read once from `NestedClass` (its ordinal-0
    // column is the nested type's Id), so a top-level test is an O(1) membership
    // check rather than a per-row `enclosing` scan of a relation that need not be
    // sorted — which would make this whole scan quadratic.
    var nested = Set<Int>()
    if let relation = opened(Metadata.Tables.NestedClass.number) {
      for row in 0 ..< Int(relation.rows) {
        nested.insert(Tuple(row, relation, self)[0])
      }
    }
    // Each top-level value `TypeDef` as its `Id`, CLR namespace, and simple
    // name, with a tally of how many distinct top-level types — of any kind —
    // bear each name.
    var values = Array<(id: Int, space: String, name: String, raw: String)>()
    var counts = Dictionary<String, Int>()
    for row in 0 ..< Int(table.rows) {
      let tuple = Tuple(row, table, self)
      guard !nested.contains(tuple.row + 1) else { continue }
      // A closure render tallies only the declarations it emits: an unreachable
      // top-level type is skipped, so it cannot make a reached name ambiguous.
      if let reached, !reached.contains(tuple.row + 1) { continue }
      let (space, raw) = try names(tuple)
      // Tally the projected (arity-stripped) name, not the raw `TypeName`, so a
      // generic `Foo` backtick `1` collides with a non-generic `Foo` exactly as
      // the two project to the one emitted `Foo`.
      let name = projected(raw)
      counts[name, default: 0] += 1
      if try kind(tuple).value {
        values.append((tuple.row + 1, space, name, raw))
      }
    }
    // A frontier the render spells but does not emit is a second distinct
    // top-level bearer of its name: bump a reached value type it collides with
    // to ambiguous, so the local definition wraps and the frontier's reference
    // no longer binds to it. A name no reached type bears is skipped — there is
    // no emitted value type to disambiguate.
    for name in contended where counts[name] != nil {
      counts[name]! += 1
    }
    // A name two or more top-level types bear is ambiguous: its value-type
    // bearers gate the decode spelling and the emit wrap, while a colliding
    // protocol or class stays bare. `names` carries two kinds of token, disjoint
    // by shape so one set threads to every seam: a bare ambiguous `TypeName` (no
    // dot) drives the decode's O(1) fast-reject and name lookups, and an
    // ambiguous value type's full `namespace.name` identity (dotted) gates the
    // value-aware qualification — a same-named protocol, class, or external
    // reference, whose identity is absent, spells bare with no per-reference
    // resolution.
    var names = Set<String>()
    var ids = Set<Int>()
    for value in values where (counts[value.name] ?? 0) >= 2 {
      names.insert(value.name)
      // The identity keys off the *raw* `TypeName`, not the projected one, so a
      // value type `A.Foo` and a same-namespace generic protocol `A.Foo` +
      // arity — which the projected name collapses to one identity — stay
      // distinct: only the value type's raw identity is here, so a reference to
      // the generic protocol (whose raw name carries the arity suffix) does not
      // match and stays bare, while the value type qualifies. The counting
      // above still uses the projected name, so the two collide and the value
      // type wraps.
      names.insert(value.space.isEmpty ? value.raw
                                       : value.space + "." + value.raw)
      ids.insert(value.id)
    }
    return (names, ids)
  }

  /// The local `TypeDef` the named type `reference` resolves to, or `nil` when
  /// it names no local definition.
  ///
  /// A `TypeDef` reference already names a local definition. A `TypeRef` resolves
  /// through its `ResolutionScope` chain — a module-scoped reference to the
  /// non-nested `TypeDef` of the same (namespace, name), a `TypeRef`-scoped
  /// (nested) reference to the nested `TypeDef` under the local definition its
  /// enclosing reference resolves to — exactly the walk the render's `references`
  /// CTE performs. A reference whose chain terminates at a `ModuleRef` or
  /// `AssemblyRef` (an external assembly) resolves to nothing; a `TypeSpec`
  /// names no definition.
  @_lifetime(copy self)
  package func definition(of reference: TypeDefOrRef)
      throws(WinMDError) -> Tuple? {
    guard let tuple = try resolve(reference) else { return nil }
    switch tuple.table.number {
    case Metadata.Tables.TypeDef.number:
      return tuple
    case Metadata.Tables.TypeRef.number:
      return try definition(reference: tuple)
    default:
      return nil
    }
  }

  /// The local `TypeDef` the `TypeRef` `tuple` resolves to through its
  /// `ResolutionScope` chain, or `nil` when the reference is external.
  @_lifetime(copy self)
  private func definition(reference tuple: borrowing Tuple)
      throws(WinMDError) -> Tuple? {
    guard let ordinal = tuple.ordinal(for: "ResolutionScope") else {
      return nil
    }
    let scope = ResolutionScope(rawValue: tuple[ordinal])
    let target = try names(tuple)
    // A `TypeRef`-scoped (tag 3) reference is nested: resolve its enclosing
    // reference to a local `TypeDef`, then match the nested `TypeDef` directly
    // under it by `TypeName` — a nested type's namespace is empty, so the match
    // is by name under the encloser, never by namespace.
    if scope.tag == 3, scope.row != 0 {
      guard let enclosing = try self.tuple(scope.row - 1,
                                           of: Metadata.Tables.TypeRef.self),
          let encloser = try definition(reference: enclosing) else {
        return nil
      }
      return try nested(target.name, in: encloser.row + 1)
    }
    // A `Module`-scoped (tag 0) reference is local and top-level; any other
    // scope — a `ModuleRef`/`AssemblyRef`, or a null scope — is external.
    guard scope.tag == 0, scope.row != 0 else { return nil }
    return try toplevel(target.namespace, target.name)
  }

  /// The non-nested local `TypeDef` named (`namespace`, `name`), or `nil` — the
  /// anchor a module-scoped reference resolves to.
  @_lifetime(copy self)
  private func toplevel(_ namespace: String, _ name: String)
      throws(WinMDError) -> Tuple? {
    guard let table = opened(Metadata.Tables.TypeDef.number) else { return nil }
    for row in 0 ..< Int(table.rows) {
      let tuple = Tuple(row, table, self)
      let (space, simple) = try names(tuple)
      guard space == namespace, simple == name else { continue }
      // A nested type shares a bare (namespace, name) with a top-level one only
      // by coincidence, and the empty namespace collapses every nested type's
      // pair — so the module-scoped reference names the non-nested definition.
      switch try enclosing(tuple) {
      case .none: return tuple
      case .some: continue
      }
    }
    return nil
  }

  /// The local nested `TypeDef` named `name` directly under the `TypeDef` at
  /// 1-based `encloser` `Id`, or `nil` — the nested reference's resolution step.
  @_lifetime(copy self)
  private func nested(_ name: String, in encloser: Int)
      throws(WinMDError) -> Tuple? {
    guard let table = opened(Metadata.Tables.NestedClass.number) else {
      return nil
    }
    // The `NestedClass` column (ordinal 0) is the nested `TypeDef` Id, the
    // `EnclosingClass` column (ordinal 1) its encloser.
    for index in 0 ..< Int(table.rows) {
      let link = Tuple(index, table, self)
      guard link[1] == encloser else { continue }
      guard let child = try self.tuple(link[0] - 1,
                                       of: Metadata.Tables.TypeDef.self) else {
        continue
      }
      if try bare(child) == name { return child }
    }
    return nil
  }

  /// The bare `TypeName` of the type `tuple` names — the empty string when it
  /// carries no such column.
  private func bare(_ tuple: borrowing Tuple) throws(WinMDError) -> String {
    guard let name = tuple.ordinal(for: "TypeName") else { return "" }
    return try tuple.string(name)
  }

  /// A `TypeName` with its CLR generic-arity suffix removed — the projected
  /// declaration name the render actually emits and the decode spells. The
  /// suffix is a backtick and an arity count (`Foo` backtick `1`), which the
  /// projection strips, so a generic `Foo` and a non-generic `Foo` project to
  /// the one Swift name and collide. The collision tally and the qualification
  /// identity key off this projected name so they match the emission; a name
  /// without the suffix is returned unchanged.
  private func projected(_ name: String) -> String {
    String(name.prefix { $0 != "`" })
  }

  /// The (namespace, name) the `TypeDef`/`TypeRef` `tuple` names — the empty
  /// string for either column it lacks.
  private func names(_ tuple: borrowing Tuple)
      throws(WinMDError) -> (namespace: String, name: String) {
    let name = try bare(tuple)
    guard let space = tuple.ordinal(for: "TypeNamespace") else {
      return ("", name)
    }
    return (try tuple.string(space), name)
  }

  /// The open table numbered `number`, or `nil` when the database omits it —
  /// the population-count slot lookup `rows(of:)`/`tuple(_:of:)` share, reduced
  /// to the `Table` for a direct row read.
  private func opened(_ number: Int) -> Table? {
    guard valid & (1 << number) != 0 else { return nil }
    let slot = (valid & ((1 << number) - 1)).nonzeroBitCount
    return tables[slot]
  }
}
