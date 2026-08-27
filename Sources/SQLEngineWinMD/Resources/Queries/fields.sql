CREATE VIEW fields AS
SELECT
  Id,
  Name
FROM
  FieldDef
WHERE
  TypeDef = :parent
