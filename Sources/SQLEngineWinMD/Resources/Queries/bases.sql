CREATE VIEW bases AS
SELECT
  b.TypeName AS base,
  NULL AS spec
FROM
  InterfaceImpl i
  JOIN TypeRef b ON i.Interface_TypeRef = b.Id
WHERE
  i.Class = :parent
UNION
SELECT
  d.TypeName AS base,
  NULL AS spec
FROM
  InterfaceImpl i
  JOIN TypeDef d ON i.Interface_TypeDef = d.Id
WHERE
  i.Class = :parent
UNION
-- A generic base interface is named through a TypeSpec: the InterfaceImpl's
-- Interface coded index tags TypeSpec, which has no TypeName of its own, so it
-- resolves through `identities` — whose TypeSpec arm names the TypeSpec by its
-- generic base's identity. Without this arm the generic base is dropped. The
-- TypeSpec's own Id rides alongside as `spec` (NULL on a plain base): the
-- generic definition's TypeName carries an invalid arity suffix and drops the
-- type arguments, so the render decodes the complete constructed spelling from
-- the TypeSpec signature rather than emitting that TypeName.
SELECT
  s.TypeName AS base,
  i.Interface_TypeSpec AS spec
FROM
  InterfaceImpl i
  JOIN identities s ON i.Interface_TypeSpec = s.Id AND s.kind = 'TypeSpec'
WHERE
  i.Class = :parent
