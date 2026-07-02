SELECT
  rowid,
  TypeNamespace,
  SANITIZE(TypeName) AS TypeName,
  iid
FROM
  interfaces
WHERE
  TypeName = :name
  OR '*' = :name
