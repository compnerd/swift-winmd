CREATE VIEW generics AS
SELECT
  Name,
  Number
FROM
  GenericParam
WHERE
  Owner_TypeDef = :parent
ORDER BY
  Number
