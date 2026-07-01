CREATE VIEW params AS
SELECT
  rowid,
  Name,
  Sequence
FROM
  Param
WHERE
  parent = :parent
