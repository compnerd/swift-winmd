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
-- Interface coded index tags TypeSpec, which has no TypeName of its own. A
-- generic instantiation (GENERICINST <base> <args…>) resolves to its generic
-- base, whose Id the adapter decodes to the TypeSpec's Base_TypeRef or
-- Base_TypeDef key -- the 1-based Id of the base in its table. So the name
-- reads through a seekable join against the TypeRef and TypeDef base tables,
-- mirroring the `identities` view's two TypeSpec arms without re-evaluating a
-- four-way UNION per InterfaceImpl row. Without these arms the generic base is
-- dropped. The TypeSpec's own Id rides alongside as `spec` (NULL on a plain
-- base): the generic definition's TypeName carries an invalid arity suffix and
-- drops the type arguments, so the render decodes the complete constructed
-- spelling from the TypeSpec signature rather than emitting that TypeName.
SELECT
  r.TypeName AS base,
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
  i.Interface_TypeSpec AS spec
FROM
  InterfaceImpl i
  JOIN TypeSpec ts ON i.Interface_TypeSpec = ts.Id
  JOIN TypeDef d ON ts.Base_TypeDef = d.Id
WHERE
  i.Class = :parent
