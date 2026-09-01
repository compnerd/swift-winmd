CREATE VIEW bases AS
-- Each plain base carries the InterfaceImpl provenance the render resolves it
-- by: `ref` is the base's `Interface_TypeRef` Id (a reference the render follows
-- through the scope chain), `def` its `Interface_TypeDef` Id (a local definition
-- named directly). Exactly one is non-NULL per plain arm. The render keys the
-- inheritance spelling off the resolved *identity* rather than correlating the
-- name against a separate query — an external base that merely shares a bare
-- `TypeName` with a local nested interface must not adopt the local one's Id.
SELECT
  b.TypeName AS base,
  b.Id AS ref,
  NULL AS def,
  NULL AS spec
FROM
  InterfaceImpl i
  JOIN TypeRef b ON i.Interface_TypeRef = b.Id
WHERE
  i.Class = :parent
UNION
SELECT
  d.TypeName AS base,
  NULL AS ref,
  d.Id AS def,
  NULL AS spec
FROM
  InterfaceImpl i
  JOIN TypeDef d ON i.Interface_TypeDef = d.Id
WHERE
  i.Class = :parent
UNION
-- A generic base interface is named through a TypeSpec: the InterfaceImpl's
-- Interface coded index tags TypeSpec, which has no TypeName of its own. The
-- name reads through a seekable join against the TypeRef and TypeDef base
-- tables, mirroring the `identities` view's two TypeSpec arms. The TypeSpec's
-- own Id rides alongside as `spec` (NULL on a plain base); the render omits a
-- generic base (`spec IS NULL`), so its `ref`/`def` are NULL.
SELECT
  r.TypeName AS base,
  NULL AS ref,
  NULL AS def,
  i.Interface_TypeSpec AS spec
FROM
  InterfaceImpl i
  JOIN TypeSpec ts ON i.Interface_TypeSpec = ts.Id
  JOIN TypeRef r ON ts.Base_TypeRef = r.Id
WHERE
  i.Class = :parent
UNION
SELECT
  d.TypeName AS base,
  NULL AS ref,
  NULL AS def,
  i.Interface_TypeSpec AS spec
FROM
  InterfaceImpl i
  JOIN TypeSpec ts ON i.Interface_TypeSpec = ts.Id
  JOIN TypeDef d ON ts.Base_TypeDef = d.Id
WHERE
  i.Class = :parent
