SELECT
  rowid,
  TypeNamespace,
  ESCAPE(TypeName) AS TypeName,
  iid
FROM
  interfaces
WHERE
  TypeName = :name
  OR '*' = :name
