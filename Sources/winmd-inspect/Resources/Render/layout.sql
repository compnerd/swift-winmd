-- Whether the value type at `:parent` has an ABI layout the `@frozen` struct
-- projection cannot faithfully reproduce: it returns the type's `Id` when the
-- type must be rejected, no row when it renders safely.
--
-- Only a sequential layout is safe. The `0x18` LayoutMask (§II.23.1.15) marks a
-- value type auto (`0x00`), sequential (`0x08` tdSequentialLayout), or explicit
-- (`0x10` tdExplicitLayout). An auto layout lets the runtime lay the fields out
-- in whatever order it chooses, so their declaration (FieldDef) order need not
-- be their memory order — a Swift `struct`, which lays its stored properties out
-- in source order, would then mismatch. An explicit layout places fields at
-- declared offsets — an overlapping union or a hand-laid record — which a Swift
-- `struct` cannot express. Only a sequential layout guarantees the fields lie in
-- declaration order at their natural offsets, the one arrangement a `struct`
-- reproduces, so the check admits `0x08` alone and rejects auto, explicit, and
-- the reserved `0x18`.
--
-- A non-default packing (a `ClassLayout` row whose `PackingSize` is not zero)
-- tightens the fields below their natural alignment, shifting every offset past
-- the first. A declared size (a `ClassLayout` row whose `ClassSize` is not zero,
-- §II.22.8) fixes the total in-memory extent — padding the record out to a
-- larger size, or forcing tail padding a naturally-laid struct would not carry —
-- which no `@frozen` `struct` reproduces either. `@frozen` only freezes the
-- layout Swift itself chooses; it applies neither an explicit offset, a packing,
-- nor a declared size, so such a type would decode to the wrong size and field
-- offsets when passed to a native API. The closure walk rejects a type this
-- query returns a row for, leaving it a frontier the consumer defines rather
-- than an ABI-incompatible declaration. A `ClassSize` of zero is unspecified
-- (the natural size stands), so it is safe; any non-zero declared size is
-- rejected conservatively.
--
-- `ClassLayout` is an optional table (`table(named:)` resolves it to an empty
-- relation when absent), so a database with no laid-out type reads no packing or
-- size row and the LEFT JOIN yields NULL, which `COALESCE` treats as the default.
SELECT
  t.Id
FROM
  TypeDef t
  LEFT JOIN ClassLayout c ON c.Parent = t.Id
WHERE
  t.Id = :parent
  AND (BITAND(t.Flags, 24) <> 8
       OR COALESCE(c.PackingSize, 0) <> 0
       OR COALESCE(c.ClassSize, 0) <> 0)
