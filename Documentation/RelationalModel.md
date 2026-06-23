# The Relational Model, Applied to WinMD

A `.winmd` file is **raw, offset-addressable data wrapped in a stack of nested
envelopes** — an MS-DOS stub around a PE/COFF image around a CLI header around a
metadata root around a set of streams (see
[DatabaseModel.md](DatabaseModel.md)). At the bottom of that stack sit a tables
stream and a few heaps whose shape happens to be exactly that of a fixed set of
relations: a statically known schema, rows addressed by index, and cross-table
references that behave like foreign keys.

This library **projects a relational model onto those bytes** as a lens for
access. It does *not* turn the file into a database. There is no storage engine
underneath: nothing is loaded, inserted, indexed, or materialised. Every type —
`Database` included — is fundamentally a **`~Escapable` borrowed view over the
raw underlying bytes** (a `RawSpan`), interpreting them in place without owning
or copying them. The relational vocabulary used throughout the code (`Database`,
catalog, row descriptor, cursor, foreign key) is a well-understood way to
*structure access*, not a claim that a relational substrate exists.

Rather than invent a vocabulary, then, this library borrows the concepts that
the SQL relational model has settled on over decades and applies them as a
reading lens. This document names those concepts and shows how each maps onto
the code.

> **The model is a projection, not the substrate.** The substrate is
> envelope-wrapped metadata; the relational model is how this library *reads*
> it. Keep that distinction in mind for every mapping below — "table", "row",
> and "catalog" describe how access is organised, not what is stored.

## Why the lens fits

The tables-stream-and-heaps layer of a WinMD file — the innermost envelope, once
all the PE/CLI wrapping is unwound — has the shape of a relational database,
minus the parts that exist to support mutation:

- The schema is **fixed and known at compile time** (ECMA-335 §II.22). There is
  no DDL, no user-defined tables.
- The file is a **sealed, read-only snapshot**: no transactions, no concurrency
  control, no logging, no mutation. Once opened, nothing changes — so derived
  structures (catalog, layouts) never need invalidation.
- Every column is **fixed-width within a given database**. There is no
  null bitmap and no variable-length row walking: row *r* of a table
  begins at `r * stride`, and column *i* sits at a constant offset within it.
  This is simpler than a general engine's slotted page — a table is just a
  packed array of fixed-width rows.

These simplifications mean the *access path* reduces to its essentials: resolve
the catalog once, build a row descriptor per table, and hand out cursors. There
is no engine to speak of — only arithmetic over a buffer. The relational terms
below name the steps of that arithmetic, not components of a running database.

## Concept map

| Relational concept | WinMD / ECMA-335 | This library |
| --- | --- | --- |
| Logical schema (the catalog's table/column definitions) | The table definitions in ECMA-335 §II.22 — table number and column descriptors | `TableSchema` (`Table.swift`); the ~40 marker types in `Sources/WinMD/Tables/` |
| Physical schema / the catalog (system metadata describing the schema) | Resolved index/column byte widths, derived from the `Valid` bitvector, row counts, and `HeapSizes` | `PhysicalSchema` (`PhysicalSchema.swift`), exposed as `Database.catalog` |
| The catalog resolved once at open | Resolved once when the database is opened | `Database.catalog`, computed in `Database.init` |
| Row descriptor (precomputes each column's byte offset) | The byte offset and width of each column, pre-summed, plus the row stride | `TupleDescriptor` (`TupleDescriptor.swift`) |
| A table / open relation | One table's rows within the file | `Table` (the immutable value in `Table.swift`) |
| A row / cursor (an offset into the buffer + the shared descriptor) | A row addressed by index into the table's packed rows | `Row<Schema>` (`Iteration.swift`) |
| A (table) scan | Iterating a table's rows | `TableIterator<Schema>` |
| Foreign key | Simple index (one target table) and coded index (a tagged-union FK across several tables) | `Index.simple` / `Index.coded`; `CodedIndex` |
| Out-of-line storage, referenced by offset | The `#Strings`, `#Blob`, and `#GUID` heaps | `StringsHeap`, `BlobsHeap`, `GUIDHeap` |
| Read-only snapshot (no transactions, no concurrency control, no logging) | The sealed file | the absence of any mutation path |

## How the pieces play together

**Resolve the catalog once.** Opening a `Database` borrows the caller-owned byte
buffer (a `RawSpan`), unwraps the envelopes down to the metadata, locates the
streams, and resolves the physical schema into a `PhysicalSchema` value —
exposed as `Database.catalog`. The catalog is invariant for the file's lifetime,
so it is resolved once in the initialiser and never rebuilt. "Opening"
materialises nothing: a `Database` is a `~Escapable` borrowed view over the
buffer, not a constructed copy of it. The caller owns and keeps the buffer
alive; see the zero-copy principle in [DatabaseModel.md](DatabaseModel.md).

**Resolve a row descriptor per table.** With the catalog in hand, each
present table is *opened* into a `Table` value. At that moment its
`TupleDescriptor` is computed once: the column widths are resolved against the
catalog and pre-summed into offsets, so that locating column *i* is a constant
array lookup rather than a walk over the preceding columns. The value holds the
schema, the descriptor, the row count, and the table's absolute byte range.

**Hand out cursors, not copies.** A `Row<Schema>` is a cursor: a row index over
a borrowed view of the buffer. Constructing one allocates nothing and copies
nothing. Reading column *i* computes `range + row * stride + offset[i]` and reads
the cell straight from the shared buffer as a zero-copy unaligned `RawSpan` load.
The `Schema` type parameter is a phantom — it carries no data, but lets the typed
per-table accessors (`row.Name`, `row.Flags`, …) be checked at compile time while
the runtime path stays schema-erased.

**Resolve foreign keys by following indices.** A column typed as a simple or
coded index holds a row number into another table (the coded case packs a
table discriminator into the low bits). Resolving it is a catalog lookup for the
target table followed by a cursor at that row — a foreign-key join, done
lazily on access.

## The shape this produces

Because the format is read-only and fixed-width, and because the library only
*reads* it rather than backing it with an engine, there is no machinery for the
things that make a real relational database complex. What remains is the
irreducible access path — offset arithmetic over the envelope-wrapped bytes,
dressed in relational terms:

```
borrow buffer → resolve catalog (once)
              → open each table, resolve its row descriptor (once each)
              → iterate / index → cursors (zero alloc, O(1) column access)
              → follow indices → cursors into other tables
```

See [DatabaseModel.md](DatabaseModel.md) for the concrete on-disk format and the
types that parse it.
