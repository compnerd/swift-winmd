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
UNION
-- A generic interface's base is recorded through a TypeSpec (a GENERICINST
-- signature) rather than a TypeRef/TypeDef, so join the TypeSpec, decode its
-- signature to the base coded-index token (GENERICBASE), and resolve that token
-- to the base's TypeName by splitting its tag (BITAND(token, 3)) and 1-based
-- row (token / 4): tag 1 names a TypeRef, tag 0 a TypeDef.
SELECT
  b.TypeName AS base
FROM
  InterfaceImpl i
  JOIN TypeSpec s ON i.Interface_TypeSpec = s.Id
  JOIN TypeRef b ON b.Id = GENERICBASE(s.Signature) / 4
WHERE
  i.Class = :parent
  AND BITAND(GENERICBASE(s.Signature), 3) = 1
UNION
SELECT
  d.TypeName AS base
FROM
  InterfaceImpl i
  JOIN TypeSpec s ON i.Interface_TypeSpec = s.Id
  JOIN TypeDef d ON d.Id = GENERICBASE(s.Signature) / 4
WHERE
  i.Class = :parent
  AND BITAND(GENERICBASE(s.Signature), 3) = 0
