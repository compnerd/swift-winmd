CREATE VIEW specs AS
SELECT
  s.Id AS spec
FROM
  InterfaceImpl i
  JOIN TypeSpec s ON i.Interface_TypeSpec = s.Id
WHERE
  i.Class = :parent
