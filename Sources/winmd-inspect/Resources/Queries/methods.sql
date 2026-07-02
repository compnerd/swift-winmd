CREATE VIEW methods AS
SELECT
  Id,
  Name
FROM
  MethodDef
WHERE
  parent = :parent
