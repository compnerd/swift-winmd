CREATE VIEW signatures AS
SELECT
  Id,
  Name,
  SIGNATURE(Signature) AS Type
FROM
  MethodDef
WHERE
  TypeDef = :parent
