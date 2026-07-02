SELECT
  Id,
  SANITIZE(Name) AS Name,
  Sequence
FROM
  params
