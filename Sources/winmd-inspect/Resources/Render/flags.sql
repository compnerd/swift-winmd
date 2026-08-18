-- Whether the enum `TypeDef` at `:parent` bears a `System.FlagsAttribute`
-- custom attribute — the `[flags]` marking that makes the enum a bitmask. It
-- returns the enum's `Id` when the attribute is present and no row otherwise,
-- so the render projects a `[flags]` enum as an `OptionSet` (its members
-- combine) and a plain enum as a native fixed-size Swift `enum`.
--
-- The attribute is matched by its (namespace, name) the way `guid.sql` and the
-- `interfaces` view match `GuidAttribute` — through the three encodings a
-- `CustomAttribute` names its constructor by: a `MemberRef` to a `TypeRef` (an
-- external reference, the shape real metadata uses for `System.FlagsAttribute`),
-- a `MethodDef` on the attribute `TypeDef` (a local definition), and a
-- `MemberRef` to a `TypeDef` (a `MemberRef` naming a local definition). Only the
-- namespace and name differ from `guid.sql`: `System.FlagsAttribute`, not the
-- Win32 metadata `GuidAttribute`.
--
-- `CustomAttribute`/`MemberRef` are present in real metadata; a fixture that
-- omits the matching rows simply yields no row, so the enum reads as not a
-- `[flags]` enum — the same graceful non-match the `guid` query relies on.
SELECT
  t.Id AS flags
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeRef g ON r.Class_TypeRef = g.Id
WHERE
  g.TypeNamespace = 'System'
  AND g.TypeName = 'FlagsAttribute'
  AND t.Id = :parent
UNION
SELECT
  t.Id AS flags
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MethodDef m ON c.Type_MethodDef = m.Id
  JOIN TypeDef g ON m.TypeDef = g.Id
WHERE
  g.TypeNamespace = 'System'
  AND g.TypeName = 'FlagsAttribute'
  AND t.Id = :parent
UNION
SELECT
  t.Id AS flags
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeDef g ON r.Class_TypeDef = g.Id
WHERE
  g.TypeNamespace = 'System'
  AND g.TypeName = 'FlagsAttribute'
  AND t.Id = :parent
