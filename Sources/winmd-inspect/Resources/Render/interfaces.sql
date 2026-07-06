SELECT
  Id,
  TypeNamespace,
  TypeName,
  iid
FROM
  interfaces
WHERE
  TypeName = :name
  OR '*' = :name
