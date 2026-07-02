CREATE VIEW interfaces AS
SELECT
  t.rowid,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.rowid
  JOIN MemberRef r ON c.Type_MemberRef = r.rowid
  JOIN TypeRef g ON r.Class_TypeRef = g.rowid
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
UNION
SELECT
  t.rowid,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.rowid
  JOIN MethodDef m ON c.Type_MethodDef = m.rowid
  JOIN TypeDef g ON m.parent = g.rowid
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
UNION
SELECT
  t.rowid,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.rowid
  JOIN MemberRef r ON c.Type_MemberRef = r.rowid
  JOIN TypeDef g ON r.Class_TypeDef = g.rowid
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
