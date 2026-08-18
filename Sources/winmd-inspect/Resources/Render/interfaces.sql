-- The seed row an interface renders from — its `Id`, namespace, name, and
-- `iid`, plus a literal `kind` of `interface` so the closure walk routes every
-- seed through the interface template section, the same tagged row shape the
-- `requires` and `references` selections carry.
SELECT
  Id,
  TypeNamespace,
  TypeName,
  iid,
  'interface' AS kind
FROM
  interfaces
WHERE
  TypeName = :name
  OR '*' = :name
