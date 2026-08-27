-- A struct's fields, in declaration order, through the `fields` view bound by
-- the struct's `Id` — each field's `Id` (for the render to decode its type from
-- its `FieldDef` signature) and its keyword-escaped `Name`. The render spells
-- each field's type at render time from the target `Dialect`, so the query
-- projects only the identity and name, the way `params` does for a method.
SELECT
  Id,
  SANITIZE(Name) AS Name
FROM
  fields
