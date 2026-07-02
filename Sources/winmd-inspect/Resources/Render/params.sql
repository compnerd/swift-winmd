SELECT
  rowid,
  SANITIZE(Name) AS Name,
  Sequence
FROM
  params
