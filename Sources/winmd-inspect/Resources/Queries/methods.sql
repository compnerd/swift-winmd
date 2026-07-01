CREATE VIEW methods AS
SELECT
  rowid,
  Name
FROM
  MethodDef
WHERE
  parent = :parent
