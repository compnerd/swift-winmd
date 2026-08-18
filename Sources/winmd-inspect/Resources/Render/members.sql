-- An enum's members, through the `fields` view bound by the enum's `Id` — every
-- `FieldDef` row save the `value__` instance field, which is not a member but
-- the enum's underlying storage (its type spells the enum's raw-value type,
-- decoded separately). Each surviving row is a member: its `Id` (for the render
-- to read its constant value from the `Constant` table) and its keyword-escaped
-- `Name`.
SELECT
  Id,
  SANITIZE(Name) AS Name
FROM
  fields
WHERE
  Name <> 'value__'
