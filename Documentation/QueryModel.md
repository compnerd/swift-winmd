# Query Model

The query model is how a caller reads and relates the metadata: scanning a
relation, filtering and projecting its rows, and following foreign keys between
relations. It builds directly on the [relational model](RelationalModel.md) —
relations (`Table`), rows (`Row`/`Tuple`), foreign keys (`Index`/`CodedIndex`),
and out-of-line heaps — and inherits the zero-copy, zero-allocation guarantees
of the [database model](DatabaseModel.md).

The primary use is *ad-hoc selection*: pick a subset of the API surface (a
namespace, a set of types and their members). There are two front-ends, sharing
the same underlying `~Escapable` scan and navigation primitives but otherwise
independent:

- **Textual SQL**, driven by `winmd-inspect query`, runs through a standalone
  relational engine — a SQL parser, a logical operator compiler, an optimiser,
  and an executor — over the WinMD database adapted to the engine's source
  protocols.
- **Swift combinators** — `where`/`select` over a borrowed row, and the
  `resolve`/`list`/`referencing` foreign-key navigators — are used
  programmatically, reading the WinMD views directly without going through the
  SQL engine.

## Layering

Three layers keep the textual surface decoupled from any data source:

- A standalone, **generic `SQL` module** — a lexer and parser producing a SQL
  abstract syntax tree, plus the operator algebra (compiler, optimiser,
  executor) that runs a `SELECT` against a set of adapter protocols. It knows
  nothing of WinMD: it plans and executes entirely against `Catalog`, `Table`,
  `Cursor`, and `Row`, never importing `WinMD`, and is reusable on its own.
- The **WinMD module** — cursors, typed rows, and foreign-key navigation. It is
  SQL-agnostic: it never imports the `SQL` module and is fully usable through
  the Swift combinators alone.
- **`winmd-inspect`** binds the two: `Database+SQL.swift` makes a WinMD database
  conform to the `SQL` engine's source protocols, and the `query` subcommand
  parses the input, runs it on the engine, and renders the resulting values.

## The escape boundary

The model is organised around one principle: a boundary between the borrowed
*view* layer and the escapable *query* layer.

- The **view layer** — `Database`, `Cursor`, `Tuple`, `Row`, and the engine's
  `~Escapable` adapter (`Catalog`/`Table`/`Cursor`/`Row`) — is borrowed,
  zero-copy windows over the mapped buffer; they carry `@_lifetime`
  dependencies and cannot be stored, collected, or outlive the buffer.
- The **query layer** — the SQL AST, the operator `Plan`, the engine's
  materialised `Record`, and the WinMD predicate/projection closures — is fully
  escapable. The `Plan` references each relation by its catalog *name* rather
  than by a `~Escapable` `Table` (an `indirect enum` cannot box a `~Escapable`
  payload); a WinMD closure has the form `(borrowing Tuple) -> Value`. Either
  may *read* a borrowed row, but the type system forbids *storing* one
  (`lifetime-dependent value escapes its scope`).

Queries therefore compose, parse, and plan freely on the escapable side; the
`~Escapable` views materialise only transiently, at execution, inside a borrow.
The engine copies exactly the referenced cells out of a borrowed row into an
escapable, slot-indexed `Record` at each scan leaf, so the operator tree runs
on owned tuples while every lifetime concern stays confined to the view layer.

## Relations and cursors

A relation is opened as a cursor:

- `database.rows(of: table)` — a *generic* cursor yielding `Tuple`, addressing
  columns by ordinal (`tuple[3]`), or resolving a name to an ordinal once with
  `tuple.ordinal(for: "TypeNamespace")` and reading by that ordinal.
- `database.rows(of: TypeDef.self)` — a *typed* cursor yielding `Row<Schema>`,
  addressing columns by a `Column<Schema, Value>` token (`row[.TypeName]`, with
  value-type inference and per-schema autocomplete). This is the surface for
  code that knows the table at compile time.

(Key paths are unavailable — `KeyPath<Root, Value>` requires `Root: Escapable`,
which the row views are not — so the typed column reference is the `Column`
token.)

The SQL engine does not run on either of these directly; it runs on the adapter
protocols (below), which the WinMD database conforms to.

## Textual SQL (the engine)

The generic `SQL` module lexes and parses the text into a SQL AST — a relation,
a projection (named columns or `*`), an optional predicate tree of
`column · comparison · operand` nodes composed with `AND`/`OR`/`NOT`, an
optional `JOIN … ON`, and an optional `ORDER BY`:

```sql
SELECT TypeName, TypeNamespace FROM TypeDef
 WHERE TypeNamespace = 'Windows.Win32.Foundation'
```

`winmd-inspect query` hands the parsed `SELECT` to the database-agnostic
`Engine`, which runs entirely against four adapter protocols a data source
conforms to: a `Catalog` resolves a relation name to a `Table`; a `Table`
reports its schema (real `width`, a name → ordinal map, and a `bound` for a
sorted-seek) and vends a `Cursor`; a `Cursor` addresses rows by index; a `Row`
reads a typed cell by ordinal. Every protocol is `~Escapable`, so a
borrowed-storage source — a WinMD database over a mapped file — conforms to the
same surface as an owned one. The engine yields typed `Value`s, never rendered
text; `winmd-inspect` formats each into a tab-separated line.

The engine runs the `SELECT` in three phases, each re-resolving relations by
name through the borrowed catalog:

1. **Compile.** It reads each relation's schema and shapes a logical operator
   `Plan` in slot space: a single relation becomes
   `Project(Sort(Select(Scan)))`; a join becomes the same over the Cartesian
   `Product` of two scans, the `ON` equality conjoined onto the `WHERE`
   predicate. Each `Scan` carries the relation name and exactly the ordinals the
   query references (projection ∪ filter ∪ order ∪ join keys), in a fixed order
   that defines a dense slot for each — *projection pushdown*, so a record is a
   gap-free `Array<Value>` the operators address by slot.

2. **Optimise.** Two pattern rewrites turn the logical tree physical. A `Select`
   over a full `Scan` whose predicate is (or conjoins) a sort-key equality or
   range on a *seekable* column becomes a **seeked scan** — the column's
   `[lower, upper)` run found through the `Table.bound` partition point — with
   any remaining predicate kept as a residual `Select`. A `Select` over a
   `Product` whose predicate relates an outer ordinal to an inner one becomes an
   **index-nested-loop join**: for each outer record, the inner relation is
   seeked (via `bound`) to the matching run rather than the whole product being
   formed.

3. **Execute.** The executor re-resolves each relation, opens its cursor, and
   materialises the referenced ordinals of each (seeked or full) row range into
   dense `Record` slots — reals out of the cursor, virtual columns computed by
   the row. `select` keeps the admitted records, `project` reorders to the
   projected slots, `sort` orders by a typed key, and `join` seeks the inner per
   outer record and concatenates the matches. The result is an array of typed
   `Value` rows.

### Joins over foreign keys and lists

The WinMD adapter exposes two **virtual columns** past each relation's real
fields, at ordinals outside the `SELECT *` range so a `*` never projects them:

- `rowid` — the SQLite-style 1-based row index. A foreign key is a real column
  holding a target row's `rowid`, so an equi-join over it is an ordinary FK
  join — the child's foreign-key column against the parent's `rowid`:
  `SELECT i.Interface FROM InterfaceImpl i JOIN TypeDef t ON i.Class = t.rowid`,
  where `InterfaceImpl.Class` is a simple index into `TypeDef`.
- `parent` — a list-child's owning parent's `rowid`. A list relationship (a
  parent's run of children, e.g. `TypeDef.MethodList → MethodDef`) is not a
  stored key, so the child relates to its owner through the computed `parent`
  column against the parent's `rowid`:
  `SELECT m.Name FROM TypeDef t JOIN MethodDef m ON m.parent = t.rowid`.

A *coded* index column (e.g. `TypeDef.Extends`, a `TypeDefOrRef`) exposes its
raw encoded value — the packed row-plus-tag token — not a bare row id, so
relating it to a target table's `rowid` must be spelled out explicitly.

A real column always takes precedence over a same-named pseudo-column, as in
SQLite: a table that has its own `Parent` field (`EventMap`, `PropertyMap`,
`ClassLayout`, …) resolves `Parent` to that real foreign key, so the virtual
`parent` reaches only the list-child tables that have no real `Parent` field.

Both virtual columns are seekable — `rowid` is dense and monotonic, `parent` is
monotonic over a list-child's runs — so the engine's index-nested-loop join
seeks them through the same `bound` path it uses for an intrinsic sort key. The
adapter, not the engine, knows that a WinMD foreign key or list run *is* a join;
the engine sees only seekable columns and equi-join predicates.

## Swift combinators (programmatic)

In Swift, a query filters with `where` and maps with `select`, written as
closures over a borrowed row — an ordinary expression that bypasses the SQL
engine entirely:

```swift
database.rows(of: TypeDef.self)
  .select({ $0[.TypeName] },
          where: { $0[.TypeNamespace] == "Windows.Win32.Foundation" })
  .forEach { print($0) }
```

`select(_:where:)` is the common-case entry point; chained
`where(_:).select(_:)` reads better when built up incrementally. A closure is
general but opaque — every `where` is an `O(rows)` scan — so the sorted-index
and join optimisations apply only to the SQL engine, which inspects a structured
plan rather than running a closure per row.

### Consumption

Because a `~Escapable` view cannot conform to `Sequence` and a filtered cursor's
count is unknown without scanning, combinator results are consumed through
**callback terminals** — `forEach`, `first(where:)`, `reduce`, `count` — never a
materialised array of rows. A projection yields escapable values; to surface
rows themselves, they are handed to a `(borrowing Tuple) -> Void` callback. (The
SQL engine, by contrast, materialises owned `Record`s and returns an array of
typed `Value` rows.)

### Navigation (foreign keys)

A column whose type is an `Index` or `CodedIndex` is a foreign key; navigation
is expressed on the typed row through the `Reference`, `CodedReference`, and
`List` tokens:

- **Forward, single** — `row.resolve(.Parent)` follows a simple index to the
  typed `Row<Target>?` it names; `row.resolve(.Extends)` follows a coded index
  to a type-erased `Tuple?` (its target table chosen at runtime by the tag),
  which `Row<Target>(_:)` narrows once the target is known. `O(1)`.
- **Forward, list** — `row.list(.FieldList)` yields a cursor over the
  `[start, next-row's start)` run-length range. `O(1)` to open.
- **Reverse** — `database.referencing(row, by: CustomAttribute.Parent)` yields
  a `Filter` matching the rows whose foreign key targets this row. When the
  owning relation is `Sorted` on that column (the tables-stream `Sorted`
  bitvector), this is a binary search, `O(log n)`; otherwise a linear scan, and
  it says so.

Heap columns read through their tokens: a `#Strings` or `#GUID` column through
the `Column` value token (`row[.TypeName]`), a `#Blob` column through the
`BlobColumn` token (`row[token]`, or `row.blob(token)` for the validating
read). The SQL engine reaches the same foreign-key and list joins through the
adapter's `rowid`/`parent` virtual columns described above.

## Complexity

| Operation | Cost |
| --- | --- |
| scan / closure filter | `O(rows)` |
| SQL equality/range on a seekable column | `O(log rows)` + run length |
| SQL index-nested-loop join (seekable key) | `O(outer · log inner)` + matches |
| forward foreign key (simple / coded / list) | `O(1)` |
| reverse foreign key | `O(log rows)` when `Sorted`, else `O(rows)` |
| heap resolution | `O(payload)` |

The combinator path never materialises a relation or allocates per row; a query
is a borrowed traversal of the mapped buffer. The SQL engine materialises only
the referenced cells of surviving rows into slot records, never a whole table.
