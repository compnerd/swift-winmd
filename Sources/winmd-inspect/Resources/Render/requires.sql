-- The parent interface's plain (non-generic) base and required interfaces,
-- resolved to their local interface rows (`Id`, namespace, name, and `iid`)
-- for the closure walk to enqueue. An `InterfaceImpl` names a base either
-- through a `TypeDef` (a local definition) or a `TypeRef` (a reference, local
-- or external), and each arm resolves that edge to a local interface by
-- identity.
--
-- The `TypeDef` arm joins the exact `Interface_TypeDef` Id to the `interfaces`
-- view, never remapping it back by name, so two same-named nested definitions
-- never conflate onto one row.
--
-- The `TypeRef` arm resolves a reference to a local `TypeDef` through the
-- shared `resolved(ref, def)` fragment, which follows the reference's scope
-- chain and its nesting. A `TypeRef` is local only when its `ResolutionScope`
-- chain terminates at the `Module`: `resolved`'s anchor matches a top-level
-- reference (`ResolutionScope_Module` non-null, `ResolutionScope_TypeRef`
-- null) to a non-nested local `TypeDef` by (namespace, name); its recursive arm
-- matches a nested reference (`ResolutionScope_TypeRef` non-null) to the local
-- nested `TypeDef` under the enclosing `TypeDef` its enclosing reference
-- already resolved to — by `TypeName` under that enclosing, never by namespace
-- (a nested type's namespace is empty). A nested reference whose chain
-- terminates at an `AssemblyRef` or `ModuleRef` never reaches the anchor, so an
-- external reference that merely shares a local interface's name is the natural
-- frontier and drops, and two same-named nested definitions resolve by their
-- distinct enclosings rather than conflating. A reference that resolves to no
-- local interface (an external ref, or a local type that is no interface)
-- likewise drops, the closure following only genuine local edges.
--
-- The row shape matches the `interfaces` selection so the walk emits each
-- through the same per-interface body. A generic (`TypeSpec`) base is omitted,
-- the deferral the plain `bases` projection makes.
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
  n.Id,
  n.TypeNamespace,
  n.TypeName,
  n.iid
FROM
  InterfaceImpl i
  JOIN resolved rv ON rv.ref = i.Interface_TypeRef
  JOIN interfaces n ON n.Id = rv.def
WHERE
  i.Class = :parent
UNION
SELECT
  n.Id,
  n.TypeNamespace,
  n.TypeName,
  n.iid
FROM
  InterfaceImpl i
  JOIN interfaces n ON n.Id = i.Interface_TypeDef
WHERE
  i.Class = :parent
