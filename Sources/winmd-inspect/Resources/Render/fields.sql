-- A struct's fields, in declaration order, through the `fields` view bound by
-- the struct's `Id` — each field's `Id` (for the render to decode its type from
-- its `FieldDef` signature), its keyword-escaped `Name`, its `Flags`, and its
-- raw (unsanitized) metadata name. The render spells each field's type
-- at render time from the target `Dialect`, so the query projects the identity
-- and name the way `params` does for a method; the `Flags` let the struct
-- render drop a static or literal field (the `fdStatic` bit), which is not
-- instance storage, while the enum render (which reads the same view for its
-- members) keeps them. The raw name lets the enum render find its `value__`
-- storage field by its metadata name, unaffected by a `SANITIZE` override that
-- would change the escaped spelling the way a member's does.
SELECT
  f.Id,
  SANITIZE(f.Name) AS Name,
  d.Flags AS Flags,
  f.Name AS Raw
FROM
  fields f
  JOIN FieldDef d ON d.Id = f.Id
