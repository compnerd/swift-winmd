-- The interface's plain (non-generic) bases, each projected as its raw `base`
-- TypeName paired with the local `TypeDef` `id` it resolves to — non-NULL only
-- for a local base (a directly-named `def`, or a `ref` the scope-chain walk
-- resolves), NULL for an external reference. The render spells a local base
-- through that Id's enclosing path and an external one bare, keyed off the
-- resolved identity rather than the base name: an external base sharing a bare
-- `TypeName` with a local nested interface must not adopt the local Id.
--
-- The resolution runs here, in the query, not in the `bases` view: it is the
-- scope-chain recursion `requires` performs and the engine's bundled
-- `CREATE VIEW` cannot carry a `WITH` prefix. The view supplies the base name
-- and the InterfaceImpl provenance (`ref`/`def`); `resolved(ref, def)` follows a
-- `TypeRef` to its local definition (anchoring a top-level module-scoped
-- reference to a non-nested local `TypeDef` by (namespace, name), its recursive
-- arm matching a nested reference to the local nested `TypeDef` under the
-- enclosing definition its enclosing reference already resolved to). A reference
-- whose chain terminates at an AssemblyRef or ModuleRef never anchors, so an
-- external base drops out with a NULL id. A generic (TypeSpec) base is excluded
-- by `spec IS NULL`.
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
  b.base,
  COALESCE(b.def, rv.def) AS id
FROM
  bases b
  LEFT JOIN resolved rv ON rv.ref = b.ref
WHERE
  b.spec IS NULL
