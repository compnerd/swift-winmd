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

The SQL engine is a standalone, WinMD-agnostic module: a lexer and parser for a
minimal `SELECT` dialect, plus an operator algebra (a compiler, an optimiser,
and an executor) that plans and runs a query against four adapter
protocols — `Catalog`, `Table`, `Cursor`, and `Row` — knowing nothing of any
particular data source. `winmd-inspect` adapts the WinMD database to those
protocols, exposing each table's rows along with two virtual columns — a
`rowid` (the 1-based row index) and a `parent` (a list-child's owning row) — so
that foreign-key and parent/child list relationships become ordinary equi-joins
the engine can plan and seek.

The `winmd-inspect` command-line tool exposes the reader through its `dump`,
`print-namespaces`, and `query` subcommands:

```
winmd-inspect <file.winmd> dump
winmd-inspect <file.winmd> print-namespaces
winmd-inspect <file.winmd> query \
    "SELECT TypeName, TypeNamespace FROM TypeDef \
       WHERE TypeNamespace = 'Windows.Win32.Foundation'"
```

The `query` subcommand parses the SQL, hands the parsed `SELECT` to the engine,
and renders each resulting row as a tab-separated line.

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

The package vends a `winmd-inspect` executable and a reusable `SQL` library.

## Documentation

The on-disk format and the design of the library are described in the
[`Documentation`](Documentation) directory:

- [`DatabaseModel.md`](Documentation/DatabaseModel.md) — the on-disk WinMD/ECMA-335
  format and the types used to parse it.
- [`RelationalModel.md`](Documentation/RelationalModel.md) — the read-only relational
  projection the library is modelled on.
- [`QueryModel.md`](Documentation/QueryModel.md) — selecting, filtering, and
  navigating the metadata through textual SQL and typed Swift combinators.
