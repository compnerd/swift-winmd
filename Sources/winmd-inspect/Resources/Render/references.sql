-- Resolve a signature-referenced type to its local `types` row for the closure
-- walk to classify and enqueue. A signature names a type through a
-- `TypeDefOrRef`, and the walk binds that reference's row rather than its
-- (namespace, name): a bare name conflates two nested types (which share the
-- empty namespace) and mislocates an external `TypeRef` that shares a local
-- type's identity.
--
-- The `TypeRef` arm resolves through the shared `resolved(ref, def)` fragment —
-- byte-identical to the one `requires.sql` carries — which follows the
-- reference's `ResolutionScope` chain: a reference is local only when its chain
-- terminates at the `Module`. The anchor matches a top-level, module-scoped
-- reference (`ResolutionScope_Module` non-null, `ResolutionScope_TypeRef` null)
-- to a non-nested local `TypeDef` by (namespace, name); the recursive arm
-- matches a nested reference (`ResolutionScope_TypeRef` non-null) to the local
-- nested `TypeDef` under the enclosing `TypeDef` its enclosing reference already
-- resolved to — by `TypeName` under that enclosing, never by namespace, which is
-- empty for a nested type. A reference whose chain terminates at an
-- `AssemblyRef` or `ModuleRef` never reaches the anchor, so an external
-- `TypeRef`-only reference resolves to nothing and is the natural frontier. The
-- caller binds the referenced `TypeRef` Id as `:ref`.
--
-- The `TypeDef` arm resolves a reference that already names a local definition
-- by its exact `Id`, bound as `:def` — no chain to walk. The caller binds
-- whichever of `:ref`/`:def` the reference's coded-index tag selects and leaves
-- the other NULL, so exactly one arm matches (a NULL key matches no row).
--
-- Either arm joins the resolved local `TypeDef` to the `types` view, keeping
-- only a type that resolves locally, and brings the `iid` in from the
-- `interfaces` view for a referenced interface (NULL for a value type, which
-- carries none). The `types` view's `kind` routes the row to the right template
-- section (interface/struct/enum/delegate), so the row shape matches the
-- `interfaces`/`requires` selections the walk emits through.
WITH RECURSIVE resolved(ref, def) AS (
  SELECT r.Id, d.Id
  FROM
    TypeRef r
    JOIN TypeDef d
      ON d.TypeNamespace = r.TypeNamespace
      AND d.TypeName = r.TypeName
  WHERE
    r.ResolutionScope_TypeRef IS NULL
    AND r.ResolutionScope_Module IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM NestedClass nc WHERE nc.NestedClass = d.Id
    )
  UNION
  SELECT r.Id, d.Id
  FROM
    resolved e
    JOIN TypeRef r ON r.ResolutionScope_TypeRef = e.ref
    JOIN NestedClass nc ON nc.EnclosingClass = e.def
    JOIN TypeDef d ON d.Id = nc.NestedClass AND d.TypeName = r.TypeName
)
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  i.iid,
  t.kind
FROM
  resolved rv
  JOIN types t ON t.Id = rv.def
  LEFT JOIN interfaces i ON i.Id = t.Id
WHERE
  rv.ref = :ref
UNION
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  i.iid,
  t.kind
FROM
  types t
  LEFT JOIN interfaces i ON i.Id = t.Id
WHERE
  t.Id = :def
