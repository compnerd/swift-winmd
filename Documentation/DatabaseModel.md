# The WinMD Database Model

A Windows Metadata (`.winmd`) file stores CLI metadata in the PE/COFF container
defined by ECMA-335. The file is **raw, offset-addressable data wrapped in a
stack of nested envelopes**: each layer is a `(offset, size)` region inside the
one above it, and reaching the metadata means unwrapping the envelopes in order.
This document describes that on-disk model and the types in this library that
parse it. For the conceptual framing — how this library projects a read-only
relational model onto the innermost layer — see
[RelationalModel.md](RelationalModel.md).

The relational projection sits only on the **tables stream and the heaps** (the
innermost envelope, described below). Everything above that — the DOS stub, the
PE image, the CLI header, the metadata root — is pure envelope unwrapping with no
relational character at all.

## Physical container

A `.winmd` is a PE image. Reaching the metadata is a chain of offset lookups —
each envelope yielding the next — and every layer is parsed as a zero-copy
`~Escapable` borrowed view (a `RawSpan`) into the caller's byte buffer rather
than being copied out:

1. **MS-DOS stub** → `DOSFile` (`DOSFile.swift`). Validates the `MZ` signature
   and yields the embedded PE image at `e_lfanew`.
2. **PE/COFF headers and sections** → `PEFile` (`PEFile.swift`). Exposes the data
   directories and section headers; section headers translate a relative virtual
   address (RVA) to a file offset.
3. **CLI header** (`IMAGE_COR20_HEADER`) → data directory entry 14, parsed by
   `Assembly` (`CIL.swift`). It points at the metadata root.
4. **Metadata root** → `MetadataRoot` (`CIL.swift`). Begins with the `BSJB`
   signature (`0x424A5342`), a version string, and a list of **stream headers**.

## Streams

The metadata root carries a handful of named streams (`StreamHeader`,
`Metadata.Stream`), each a `(offset, size)` region of the metadata blob:

| Stream | Contents | Type |
| --- | --- | --- |
| `#~` | The tables stream: table headers followed by packed records | `TablesStream` |
| `#Strings` | NUL-terminated UTF-8 strings, referenced by byte offset | `StringsHeap` |
| `#US` | User strings (UTF-16) | — |
| `#GUID` | A packed array of 16-byte GUIDs, referenced by 1-based index | `GUIDHeap` |
| `#Blob` | Length-prefixed byte blobs, referenced by byte offset | `BlobsHeap` |

The three heaps are out-of-line storage: a column does not hold a string or blob,
it holds an **index** into the relevant heap.

- `StringsHeap[offset]` decodes a NUL-terminated UTF-8 string starting at
  `offset`.
- `BlobsHeap[offset]` reads a compressed length prefix (1, 2, or 4 bytes,
  selected by the top bits of the first byte) and returns the following bytes as
  a `Blob` (a `~Escapable` `RawSpan` view — no copy).
- `GUIDHeap[index]` returns the `index`-th GUID; the index is 1-based, with 0
  meaning "none".

## The tables stream (`#~`)

`TablesStream` (`TablesStream.swift`) parses the heart of the database. Its
header is:

```
uint32  Reserved
uint8   MajorVersion
uint8   MinorVersion
uint8   HeapSizes        ; bit 0/1/2 → #Strings/#GUID/#Blob index is 4 bytes (else 2)
uint8   Reserved
uint64  Valid            ; bitvector: which table numbers are present
uint64  Sorted           ; bitvector: which tables are sorted
uint32  Rows[]           ; one row count per present table, in table-number order
uint8   Tables[]         ; the packed records of every present table, concatenated
```

`Valid.nonzeroBitCount` gives the number of present tables, hence the length of
`Rows[]`. The record data for the tables follows immediately, one table after
another in ascending table-number order.

## Columns and indices

Each table's schema is a list of `Field`s (`Table.swift`), exposed through the
schema's `fields` accessor. A field's `ColumnType` is either:

- `.constant(n)` — an inline integer of `n` bytes; or
- `.index(Index)` — a reference, where `Index` is one of:
  - `.heap(.string | .blob | .guid)` — an index into a heap;
  - `.simple(TableSchema.Type)` — a row number into one specific table (a
    foreign key);
  - `.coded(CodedIndex.Type)` — a tagged-union foreign key across several
    tables, with a table discriminator packed into the low bits and the row
    number in the rest (`CodedIndex` in `CodedIndex.swift`).

The **width** of an index column is not fixed by the spec — it is 2 bytes when
the largest thing it can address fits, else 4. `PhysicalSchema`
(`PhysicalSchema.swift`) computes every index width from `HeapSizes`, the `Valid`
bitvector, and the row counts. This is the database's *physical schema*, exposed
as `Database.catalog`.

## How the library models it

The library *projects* a read-only relational model onto the tables stream and
heaps (see [RelationalModel.md](RelationalModel.md)). None of the types below
materialise a database; each is a view that interprets the raw bytes in place:

- **`TableSchema`** — the static, compile-time logical schema of a table: its
  number and `fields`. The ~40 types in `Sources/WinMD/Tables/` are
  uninstantiable markers conforming to it (e.g. `Metadata.Tables.MethodDef`).
- **`PhysicalSchema`** — an immutable value holding the resolved physical schema
  (all index/column byte widths). Resolved once when the database is opened and
  exposed as `Database.catalog`.
- **`Table`** — an immutable value describing an *open* table: a schema, a
  `TupleDescriptor`, the row count, and the table's absolute byte `range`. The
  present tables are opened once at database open.
- **`TupleDescriptor`** (`TupleDescriptor.swift`) — a row's physical layout: each
  column's precomputed byte offset (pre-summed) and width, plus the row
  `stride`. Computed once per open table.
- **`Row<Schema>`** — a cursor over a borrowed view: a row index that decodes a
  cell on demand by arithmetic against the descriptor — `range + row * stride +
  offset[i]`, a zero-copy unaligned `RawSpan` load. No allocation, no copy.
- **`TableIterator<Schema>`** — a (table) scan over a table's rows, yielding a
  typed `Row` cursor for each.
- **`Database`** (`Database.swift`) — the entry point, and itself a `~Escapable`
  borrowed view over the caller's byte buffer (a `RawSpan`): it does not own or
  copy the bytes. It exposes `catalog` (the physical schema) and the open
  tables; `rows(of:)` returns a typed iterator, `tables` lists the open tables,
  and the heaps resolve indices to their contents.

## Design principles

- **Everything is a view.** Every level — `Database`, DOS stub, PE image,
  streams, heaps, blobs, rows — is a `~Escapable` borrowed view (a `RawSpan`)
  sharing the lifetime of a single byte buffer. The format is entirely
  offset-addressable, so nothing is ever re-materialised; the library reads the
  bytes in place rather than constructing a database from them. This holds
  literally in the type system: `Database` does not own or copy the buffer,
  and reads are zero-copy unaligned `RawSpan` loads at absolute byte offsets. The
  caller owns the mapping and keeps it alive — `winmd-inspect` memory-maps the
  file with `Data(contentsOf:options: .alwaysMapped)` and constructs
  `Database(data.span.bytes)`, a `RawSpan` straight over the mapping. The read
  path is zero-copy from the file all the way through to each record.
- **Zero allocation on the hot path.** Schema layout is resolved once per table
  at open. Reading a row constructs only a small cursor value and decodes
  exactly the columns that are touched.
- **Resolve once.** The catalog (index widths) and each table's row descriptor
  are invariant for the file's lifetime and are computed a single time when the
  database is opened, not on each access.
- **O(1) column access.** Column offsets are pre-summed so locating a column is a
  constant array lookup rather than a walk over preceding columns.
