CREATE VIEW params AS
SELECT
  Id,
  Name,
  Sequence
FROM
  Param
WHERE
  MethodDef = :parent
