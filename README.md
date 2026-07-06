# Swift/WinMD

An ECMA-335 metadata reader in Swift

<p align="center">
  <a href="https://github.com/compnerd/swift-winmd/actions?query=workflow%3Awindows">
    <img alt="Windows Status" src="https://github.com/compnerd/swift-winmd/workflows/windows/badge.svg">
  </a>
  <a href="https://codecov.io/gh/compnerd/swift-winmd">
    <img src="https://codecov.io/gh/compnerd/swift-winmd/branch/main/graph/badge.svg?token=35H0KMEOAF"/>
  </a>
</p>

[Windows Metadata](https://docs.microsoft.com/en-us/uwp/winrt-cref/winmd-files) provides the necessary metadata for Windows APIs to enable generating bindings for different languages.  In order to generate the bindings, one must be able to process the metadata.  [Swift/WinMD](https://github.com/compnerd/swift-winmd) provides an implementation of such a reader in Swift.

Beyond parsing, the library projects the metadata as a read-only relational
database. Its tables stream and heaps are read as a fixed set of relations with
rows, foreign keys, and out-of-line heaps, all as zero-copy `~Escapable`
borrowed views over the caller's bytes. That database can be **queried** in two
ways: a typed Swift combinator surface (`where`/`select` over a borrowed row,
with `resolve`/`list`/`referencing` foreign-key navigation), and textual SQL run
through a small, self-contained relational engine.

## Code generation as a database

The library goes one step further and treats **code generation as a database
problem**: the generated source is a *view* over the metadata, and the rules
that decide what a COM interface *is* are written as SQL rather than as Swift.
The pipeline is a stack of decoupled layers:

- **WinMD reader** (`Sources/WinMD/`) — reads the ECMA-335 tables stream and
  heaps in place, as a fixed set of relations. It is SQL-agnostic and never
  imports the engine.
- **SQL engine** (`Sources/SQL/`) — a standalone, WinMD-agnostic relational
  engine: a lexer and parser for a `SELECT` dialect, plus an operator algebra
  (a compiler, an optimiser, and an executor) that plans and runs a query
  against four adapter protocols — `Catalog`, `Table`, `Cursor`, and `Row` —
  knowing nothing of any particular data source.
- **`winmd-inspect`** (`Sources/winmd-inspect/`) — binds the two. It adapts the
  WinMD database to the engine's protocols, expresses the COM-interface schema as
  declarative SQL views (`Sources/winmd-inspect/Resources/Queries/`), and
  renders a query's rows through [Mustache](https://mustache.github.io)
  templates (`Sources/winmd-inspect/Resources/Templates/`) to emit source.

The adapter surfaces each table's real columns and adds a universal virtual
column, `Id` (the 1-based row identity), sitting past the `SELECT *` extent. A
foreign key is a real column holding a target row's `Id`, so a foreign-key or
parent/child list relationship becomes an ordinary equi-join the engine can plan
and seek. A list-owned child additionally carries an **owner foreign key** — a
column named for its owning table (e.g. a `MethodDef`'s `TypeDef`) — and a coded
index yields one decoded join key per candidate target
(`Parent_TypeDef`, `Class_TypeRef`, …). WinMD-specific decodes are exposed as
scalar functions over the raw cells rather than as columns; for example
`GUID(blob)` decodes a `GuidAttribute` value blob to the IID it names.

For the full design, see [`SynthesisModel.md`](Documentation/SynthesisModel.md).

## The SQL dialect

The engine implements a portable subset of ISO SQL, WinMD-agnostic and reusable
on its own. The authoritative grammar lives as the doc-comment atop
`Sources/SQL/Parser.swift`; in summary it supports:

- **Statements** — `SELECT`; `WITH [RECURSIVE]` common table expressions;
  `SELECT … UNION [ALL] …`; `CREATE VIEW`; and `CREATE FUNCTION`.
- **Clauses** — `FROM` (optional: a bare `SELECT 1 + 1` computes a scalar),
  `JOIN … ON a = b`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY` (multi-key, each
  `ASC`/`DESC`), and the ISO row-limiting `OFFSET n ROWS` /
  `FETCH { FIRST | NEXT } [n] ROWS ONLY`.
- **Projection** — `*`, bare columns, or expressions with an optional `AS`
  alias; `DISTINCT` or `ALL`.
- **Predicates** — the comparison operators (`=`, `<>`, `<`, `>`, `<=`, `>=`),
  `IS [NOT] NULL`, and `AND`/`OR`/`NOT`, with parentheses.
- **Expressions** — arithmetic (`+ - * /`, precedence-aware), literals, column
  references, aggregates, and scalar-function calls.
- **Aggregates** — `COUNT(*)`, and `COUNT`/`SUM`/`MIN`/`MAX`/`AVG` over an
  expression.
- **Value types** — integer, double, text, boolean (`TRUE`/`FALSE`), and blob
  (`x'48656c6c6f'`). Text uses single quotes with `''` for an embedded quote.
- **Identifiers** — bare, or delimited with double quotes (`"Type Name"`) to
  spell a name verbatim; a dotted bare identifier (`t.Name`) is qualified.
- **Routines** — `BITAND(x, y)` is the built-in bitwise AND (the engine's only
  prelude routine). `winmd-inspect` additionally registers the `GUID(blob)`
  decode. `CREATE FUNCTION f(x INTEGER) RETURNS INTEGER AS <expression>` defines
  a scalar function over an expression body.
- **Introspection** — the `information_schema.tables` and
  `information_schema.columns` views (over a `definition_schema` base) list the
  database's relations, views, and their columns.

The dialect is a clean subset of the standard; there is no vendor-specific
`LIMIT`, and comparisons use `<>` for inequality.

## The `winmd-inspect` tool

The `winmd-inspect` command-line tool exposes the reader through two
subcommands — `query` (the default) and `dump`:

```
winmd-inspect <file.winmd> dump
winmd-inspect <file.winmd> \
    "SELECT DISTINCT TypeNamespace FROM TypeDef ORDER BY TypeNamespace"
winmd-inspect <file.winmd> query \
    "SELECT TypeName, TypeNamespace FROM TypeDef \
       WHERE TypeNamespace = 'Windows.Win32.Foundation'"
```

`dump` prints the metadata version and every table's rows. `query` parses the
SQL, hands the parsed statement to the engine, and renders each resulting row as
a Unicode box-drawing table:

```
┌──────────┬──────────────────────────┐
│ TypeName │ TypeNamespace            │
├──────────┼──────────────────────────┤
│ HWND     │ Windows.Win32.Foundation │
│ …        │ …                        │
└──────────┴──────────────────────────┘
```

### The interactive shell

Running `query` with no SQL argument opens an interactive shell (SQL may also be
piped on stdin). Statements run as they are entered; a `;` is optional. In
addition to SQL, the shell understands a set of `.`-prefixed metacommands:

```
winmd> .tables                    -- list the database's tables
winmd> .schema SELECT * FROM TypeDef
                                  -- print a query's result columns and types
winmd> .bind ns 'Windows.Win32.Foundation'
                                  -- bind a :ns parameter for later queries
winmd> SELECT TypeName FROM TypeDef WHERE TypeNamespace = :ns;
winmd> .render IUnknown com       -- render a COM interface through a template
winmd> .render * com              -- render every interface
winmd> .template t '{{! language: swift }}…'
                                  -- define an inline Mustache template
winmd> .read queries.sql          -- run a file of ;-separated statements
winmd> .help                      -- list the metacommands
winmd> .quit
```

A `-I <directory>` option prepends a search directory for the query, view, and
template resource files, so a caller can override the bundled ones without
rebuilding.

## Build Requirements

- A Swift 6.4 development toolchain

The package uses `RawSpan`, `Span`, and `InlineArray` along with the experimental
`Lifetimes` feature, which the package enables for you; no additional flags are
required.

When building on an Apple platform, the macOS 26 SDK is required.

Build it with the Swift Package Manager:

```
swift build
swift test
```

The package vends a `winmd-inspect` executable and two reusable libraries: the
generic `SQL` engine and the `WinMDSynthesis` code-generation support.

## Documentation

The on-disk format and the design of the library are described in the
[`Documentation`](Documentation) directory:

- [`DatabaseModel.md`](Documentation/DatabaseModel.md) — the on-disk WinMD/ECMA-335
  format and the types used to parse it.
- [`RelationalModel.md`](Documentation/RelationalModel.md) — the read-only relational
  projection the library is modelled on.
- [`QueryModel.md`](Documentation/QueryModel.md) — selecting, filtering, and
  navigating the metadata through textual SQL and typed Swift combinators.
- [`SynthesisModel.md`](Documentation/SynthesisModel.md) — code generation as a
  database: the schema layers, the declarative views, and the render pipeline.
</content>
</invoke>
