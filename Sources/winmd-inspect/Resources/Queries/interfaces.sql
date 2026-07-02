CREATE VIEW interfaces AS
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeRef g ON r.Class_TypeRef = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
UNION
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MethodDef m ON c.Type_MethodDef = m.Id
  JOIN TypeDef g ON m.parent = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
UNION
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeDef g ON r.Class_TypeDef = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND BITAND(t.Flags, 32) = 32
