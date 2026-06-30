# The Synthesis Model

This library generates COM interface source — `@com` protocols with their IID,
base, and method requirements — from Windows Metadata. It does so by treating
**code generation as a database problem**: the generated text is a *view* over
the metadata, and the rules that say what an interface *is* are written as SQL,
not as Swift.

The design is an ANSI-SPARC three-schema architecture with a Sheth–Larson
federation layer. The metadata reader ([DatabaseModel.md](DatabaseModel.md),
[RelationalModel.md](RelationalModel.md)) supplies the physical layer; a
generic, dialect-agnostic SQL engine ([QueryModel.md](QueryModel.md)) runs over
it; declarative views express the COM-interface logical schema; WinMD-specific
codecs supply the byte-format decoding; and a Mustache template renders the
result. This document describes that layering and the principle that organises
it.

## The schema layers

| Layer | Role (ANSI-SPARC) | What it is | Where it lives |
| --- | --- | --- | --- |
| Physical / internal | Internal schema | ECMA-335 tables, heaps, coded indices | `Sources/WinMD/` |
| Conceptual | Conceptual schema | metadata as relations: real columns + `rowid`/`parent` + decoded join keys | `Sources/winmd-inspect/Database+SQL.swift` |
| External | External schema | COM-interface *views* (`interfaces`/`methods`/`params`/`bases`) | `Sources/winmd-inspect/Resources/Queries/*.sql` |
| Federation | Component-schema codecs | signature → type spelling; GuidAttribute blob → IID; coded index → join key | `Sources/WinMDSynthesis/`, the decoded columns in `Database+SQL.swift` |
| Presentation | — | Mustache template rendering rows to source | `Sources/winmd-inspect/Shell.swift` |

Underneath all of it is a **generic SQL engine** (`Sources/SQL/`) that knows
nothing of WinMD. It plans and executes against four adapter protocols; WinMD is
just one `Catalog` it happens to run over.

```
  COM interface source                      .render  (Mustache template)
        ▲
  External schema    interfaces / methods / params / bases   (SQL views)
        ▲
  Conceptual schema  relations: real cols + rowid/parent + <Col>_<Target> keys
        ▲                                   (WinMD → SQL adapter)
        │  ── federation codecs ──  signature→type · blob→IID · coded-index→key
        ▼
  Physical schema    ECMA-335 tables / heaps / coded indices  (WinMD reader)
        ▲
  Generic SQL engine over Catalog / Table / Cursor / Row  (dialect-agnostic)
```

## Internal schema — the physical layer

A `.winmd` file is a PE/COFF image wrapping ECMA-335 CLI metadata: a tables
stream of fixed-width records, three heaps (`#Strings`, `#Blob`, `#GUID`), and
cross-table references encoded as simple and coded indices. The `WinMD` module
reads this in place as a stack of `~Escapable` borrowed views over the mapped
bytes — zero copy, zero allocation on the read path. See
[DatabaseModel.md](DatabaseModel.md) for the on-disk format and
[RelationalModel.md](RelationalModel.md) for the relational lens applied to it.

This layer is *physical*: it concerns byte offsets, index widths, and record
strides. It has no notion of what a COM interface is.

## The generic SQL engine

`Sources/SQL/` is a standalone relational engine — lexer, parser, operator
algebra — that never imports `WinMD`. It runs entirely against four
`~Escapable` adapter protocols (`Sources/SQL/Adapter.swift`):

- **`Catalog`** resolves a relation `name` to a `Table` (and a `view(named:)`
  for registered views).
- **`Table`** reports its schema: real `width` (the extent of `SELECT *`), the
  column `names`, the `virtuals` past them, an `ordinal(of:)` lookup, and a
  `bound(_:_:strict:)` partition point for a sorted seek; it vends a `Cursor`.
- **`Cursor`** addresses rows by index.
- **`Row`** reads a typed cell by ordinal, as a `Value` — `.null`, `.integer`,
  or `.text`.

`Engine.run(_:_:_:bindings:)` (`Sources/SQL/Engine.swift`) plans and executes a
`Query` in three phases — **compile → optimise → execute**:

1. **Compile** shapes a logical operator tree in dense slot space:
   `Project(Sort(Select(Scan)))` for a single relation, the same over a
   `Product` of scans for a join, with each `JOIN … ON` equality conjoined onto
   the `WHERE`. Projection pushdown means a record carries only the referenced
   ordinals.
2. **Optimise** rewrites the logical tree physical: a `Select` over a `Scan` on
   a *seekable* column becomes a seeked scan (via `Table.bound`), and a `Select`
   over a `Product` relating an outer ordinal to an inner one becomes an
   index-nested-loop `Join`.
3. **Execute** materialises the referenced cells of surviving rows into escapable
   slot `Record`s and runs the operators on owned tuples.

The operators are the textbook relational algebra: **scan, select (σ), project
(π), sort (τ), product (×), join (⋈), union (∪)**. Engine features the synthesis
layer relies on:

- **Three-valued logic.** `NULL` on either side of a comparison yields UNKNOWN;
  Kleene `AND`/`OR`/`NOT`; admission requires a definite `true`
  (`Sources/SQL/Filter.swift`). `IS [NOT] NULL` (`Predicate.null`) is a definite
  test, never UNKNOWN — load-bearing for the `params` view (below).
- **Multi-way joins** built as a left-deep chain, each `ON` equality optimised
  into an index-nested-loop join over a seekable key.
- **`CREATE VIEW`** (`Statement.create(name:view:)`) registers a named `Query`
  that the catalog resolves and the engine compiles as a derived sub-plan,
  shadowing a base table of the same name.
- **`UNION` / `UNION ALL`** (`Query.union(_:_:all:)`), concatenating arms with
  optional deduplication.
- **Bound parameters** (`:name`, `Predicate.bound`) supplied through the
  `bindings: Bindings` argument — the engine's **correlated-subquery primitive**:
  binding a parent row's key into a child query is how the render walks a
  one-to-many relationship one level at a time.
- **Registered scalar functions** (`Routines`, `Sources/SQL/Function.swift`) —
  the engine's extension point. The render binds the target-language `ESCAPE`
  UDF (below) here, so keyword-escaping is a value a query projects rather than
  logic in the binary.

The engine yields typed `Value` rows, never rendered text.

## Conceptual schema — the WinMD → SQL adapter

`Sources/winmd-inspect/Database+SQL.swift` makes a `WinMD.Storage` an
`SQL.Catalog` directly: the borrowed storage *is* the catalog, `WinMDRelation`
is a `Table`, `WinMDCursor` a `Cursor`, `WinMDRow` a `Row`. This is the
conceptual schema — the metadata presented as relations a query can navigate.

A relation's **real columns** are its ECMA-335 fields (a `#Strings` cell typed
`.text`, everything else `.integer`). Past them, at ordinals outside the
`SELECT *` extent so a `*` never projects them, sit the **virtual columns**:

- **`rowid`** — the SQLite-style 1-based row index, exposed by every relation.
  A simple foreign key is a real column holding a target's `rowid`, so an
  equi-join over it is an ordinary FK join.
- **`parent`** — a list-child's owning parent's `rowid` (e.g.
  `MethodDef`'s owning `TypeDef`), computed from the parent's run-length list
  column. A list relationship is not a stored key, so the child relates to its
  owner through this computed column. As in SQLite, a real `Parent` field always
  shadows the virtual one, so `parent` reaches only the genuine list-child
  tables.

Both virtual columns are **seekable** — `rowid` is dense and monotonic, `parent`
is monotonic over a child's runs — so the engine's index-nested-loop join seeks
them through the same `bound` path it uses for an intrinsic sort key. The
adapter, not the engine, knows that a WinMD foreign key or list run *is* a join.

### Decoded columns — the federation codecs surfaced as relations

Two further kinds of virtual column expose WinMD's *serialization formats* as
ordinary readable cells, so that views can navigate over them:

- **Per-table decoded extra.** `CustomAttribute.guid` decodes a WinMD-specific
  column (the UUID a `GuidAttribute` blob names, or `NULL` when the blob is not
  GUID-shaped), computed in `WinMDRow`, decoded rather than stored, and never
  seekable. A signature's return/parameter *type* is deliberately **not** a
  column: the adapter stays type-neutral and the render decodes the spelling from
  the signature at render time (see Presentation), so no target language leaks
  into the conceptual schema.
- **Coded-index join keys.** For every real coded-index column, the adapter
  exposes one decoded column per candidate target table the coded index admits,
  named **`<Column>_<Target>`** (e.g. `CustomAttribute.Parent_TypeDef`). Its
  value is the target's `rowid` when the cell's tag selects *that* target and is
  non-null, else SQL `NULL`. So an equi-join `JOIN Target ON
  child.<Col>_<Target> = Target.rowid` navigates the relationship *exactly* —
  the `NULL` for any other tag means the join admits only the rows whose coded
  index actually points at `Target`. These keys are derived purely from the
  schema's coded-index fields and their `CodedIndex.tables`; no table or column
  is special-cased.

A `Session` (`Database+SQL.swift`) is the same `Catalog` overlaid with the
session's registered views, so a `SELECT` may name a view, and a view shadows a
base table of the same name.

## Federation — codecs in code, not schema

The federation layer (Sheth–Larson) is where WinMD's component formats are
decoded. Crucially, this is the *only* WinMD-specific Swift in the synthesis
path, and it is deliberately limited to **byte/format codecs**, not
relationships:

- **`WinMDSynthesis.Decode`** (`Sources/WinMDSynthesis/Decode.swift`) composes a
  decoded `SignatureType` into a type spelling: primitives, the pointer/
  reference/array family, a `System.Guid` to `IID`/`CLSID` by a parameter-name
  hint, and named types through a well-known table or their resolved simple name.
  The target spellings themselves are **not** baked in — the composition is
  parameterized by a `Dialect` the render builds from the language spec
  (`swift.lang`), so the codec is the language-neutral *structure* and the spec
  supplies the Swift (or Rust, or C) strings. The render, not the adapter,
  invokes it.
- **`Resolver`/`Identity`/`TypeResolver`**
  (`Sources/WinMDSynthesis/`) resolve the `TypeDefOrRef` references a signature
  names against a borrowed `Storage` into a `Resolver` — a `rawValue → Identity`
  table the `Sendable`, database-free decode tier reads. Because a `Database` is
  `~Escapable` and cannot be captured by a `Sendable` value, resolution is done
  eagerly while the database is in scope.
- The **coded-index join keys** and the **GuidAttribute blob decode** in
  `Database+SQL.swift` are codecs of the same kind: a coded index is a packed
  tag-plus-row encoding, and a GUID is a blob layout — byte formats, decoded
  once into a join key or a UUID string.

These are codecs because they decode a *serialization format*. They are not
relationships, and so they are not expressed in SQL.

## External schema — the COM-interface views

This is where the logical schema lives. The bundled views — the
`Resources/Queries/*.sql` that `Shell.bundled()` parses and registers — express,
*as SQL*, what a COM interface is in terms of the conceptual schema:

- **`interfaces`** — an interface's IID *is the GuidAttribute it carries*. The
  view navigates `TypeDef → CustomAttribute` to the attribute, then on to its
  declaring `GuidAttribute` type by whichever coded-index arm the attribute's
  constructor uses, the three `UNION`ed: a cross-file `Type_MemberRef →
  MemberRef.Class_TypeRef → TypeRef`, and — because the metadata attributes are
  defined in the very file that applies them, so their constructor is local — two
  same-file arms, `Type_MethodDef → MethodDef.parent → TypeDef` (the constructor
  named directly as a `MethodDef`) and `Type_MemberRef → MemberRef.Class_TypeDef
  → TypeDef` (named as a `MemberRef` back into the in-file `TypeDef`). All three
  arms filter to the `GuidAttribute` declaring type and to a `tdInterface`
  carrier (`BITAND(Flags, 32) = 32`, so a GUID-bearing coclass is not mistaken
  for an interface), projecting `CustomAttribute.guid` as the `iid`.
- **`methods`** and **`params`** — an interface's methods are the `MethodDef`
  rows it owns; a method's parameters are its `Param` rows. Each is a one-level
  navigation correlated by `:parent` against the `parent` virtual column
  (`WHERE parent = :parent`), bound per level by the render.
- **`bases`** — an interface's base *is its `InterfaceImpl`*. The view navigates
  the interface's `InterfaceImpl` rows (`i.Class = :parent`, a simple `TypeDef`
  index) to each base type's name by whichever coded-index arm the base uses, the
  two `UNION`ed: `i.Interface_TypeRef → TypeRef` for a cross-file base and
  `i.Interface_TypeDef → TypeDef` for a same-file one, each projecting the base
  type's `TypeName` as `base`.

The point: "an interface's IID is the GuidAttribute it carries" and "its base is
its InterfaceImpl" are **joins and filters in SQL**, not facts hardcoded in
Swift. Re-targeting or adjusting what gets generated is, for the most part, a
change to these views.

## Presentation — rendering

`.render <interface> <template>` in `Shell.swift` gathers the view rows into a
context and renders a Mustache template — for the one named interface, or every
interface in the database when the interface is `*`. The `SELECT`s that read the
views are themselves bundled data, loaded by name from `Resources/Render/*.sql`
(the same way the template is loaded from `Resources/Templates`), not Swift
literals. A repeatable `-I <dir>` overrides them: each query, view, template, and
language spec is first sought at `<dir>/{Render,Queries,Templates,Languages}/
<name>.<ext>` (the last `-I` winning) before the bundle, so a user can shadow or
add one without rebuilding.

What makes the output a *particular language* is kept out of the binary too. The
template names its target with a leading `{{! language: <name> }}` directive that
selects a bundled `Resources/Languages/<name>.lang` spec (e.g. `swift.lang`): the
reserved words, the escape delimiters, the no-value-return spelling, the COM-root
base, and the type spellings a signature decodes to. The spec surfaces to the
render as the `ESCAPE(identifier)` UDF (keyword-escape a synthesized name) and as
a `Dialect` — the type-spelling table (plus the same keyword escape) the render's
`SignatureType` decode composes with, so a named type whose simple name is a
keyword spells escaped just as a declaration name does. A language rule is data,
not a branch in the binary; retargeting to Rust or C is a new template and spec,
no code change.

1. Run `interfaces` for every interface's `rowid`, namespace, `ESCAPE`d name, and
   `iid`, then keep the one whose name matches (or all of them for `*`).
2. Bind that `rowid` as `:parent` and run `methods` (each `Name` `ESCAPE`d) and
   decode each method's return type from its signature with the `Dialect`,
   omitting the clause when it is the spec's no-value `void`; then bind *its*
   `rowid` as `:parent` and run `params` — the correlated walk down the
   one-to-many relationships, one bound-parameter level at a time. The return
   pseudo-parameter (`Sequence == 0`) is dropped, and each real parameter's type
   is decoded at render time from its signature position.
3. Bind the interface's `rowid` and run `bases`; a rootless interface defaults to
   the spec's COM `root`, except the root interface itself, which inherits
   nothing (so `IUnknown` never becomes its own base).
4. Render the context through the template, which emits the `@com(interface:)`
   attribute, `public protocol <name>` with an optional `: <base>` clause, and
   one `func` requirement per method with an optional ` -> <returns>` clause —
   each optional driven off the value's *presence* (`{{#base}}`/`{{#returns}}`),
   not a flag. Interpolations are raw (`{{{…}}}`) because the output is Swift
   source, not HTML — angle brackets in `UnsafePointer<…>` must not be escaped.

## The interactive surface

`winmd-inspect query` (`Sources/winmd-inspect/Query.swift`) is the entry point.
Given a SQL string it runs one query; given none it opens a `sqlite3`-style shell
over the memory-mapped database — a literal `for`-in over a `Statements` stream,
running each statement through `Shell.execute`. The shell offers:

- bare SQL, run through the same `Engine` and printed tab-separated;
- `CREATE VIEW …`, registering a session view that subsequent queries may name;
- `.read <path>`, running a file of `;`-separated statements (registering views
  and printing selects), so user-authored views compose with the bundled ones;
- `.render <interface> <template>` (with `*` for the whole database), the
  rendering pipeline above;
- `.tables`, `.help`, `.quit`.

Meta-commands take a `.` prefix precisely so the SQL `:name` parameter syntax
stays free for bindings.

## The guiding principle

> **Grow the logical schema in views, not code; only codecs are code.**

Relationships — what an interface *is*, how it connects to its IID, its methods,
its base — are declarative SQL over the conceptual schema. Byte and format
decoding — a signature's type spelling, a GUID blob, a coded index's tag — is
Swift, because those are serialization formats, not relationships. The split is
deliberate: adjusting or re-targeting generated output is, wherever possible, a
change to SQL views and a Mustache template rather than to Swift, and the generic
SQL engine underneath remains entirely unaware that WinMD exists.
