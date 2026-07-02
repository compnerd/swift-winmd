CREATE VIEW bases AS
SELECT
  b.TypeName AS base
FROM
  InterfaceImpl i
  JOIN TypeRef b ON i.Interface_TypeRef = b.Id
WHERE
  i.Class = :parent
UNION
SELECT
  d.TypeName AS base
FROM
  InterfaceImpl i
  JOIN TypeDef d ON i.Interface_TypeDef = d.Id
WHERE
  i.Class = :parent
