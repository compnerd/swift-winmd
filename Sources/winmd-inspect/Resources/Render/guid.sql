-- The GUID a `TypeDef` bears through its `GuidAttribute`, decoded through the
-- `GUID` UDF the way the `interfaces` view spells an interface's `iid` — the
-- same three attribute-encoding shapes (a `MemberRef` to a `TypeRef`, a
-- `MethodDef` on the attribute `TypeDef`, a `MemberRef` to a `TypeDef`) — but
-- keyed by the `TypeDef` `Id` and ungated by the interface flag, so a delegate
-- `TypeDef` (a COM interface, not flagged an interface) still yields its
-- runtime IID for the `@com(interface:)` the render emits. A parameterised
-- delegate carries no static GUID, so this resolves nothing and the render
-- treats it as a frontier.
SELECT
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeRef g ON r.Class_TypeRef = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND t.Id = :parent
UNION
SELECT
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MethodDef m ON c.Type_MethodDef = m.Id
  JOIN TypeDef g ON m.TypeDef = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND t.Id = :parent
UNION
SELECT
  GUID(c.Value) AS iid
FROM
  TypeDef t
  JOIN CustomAttribute c ON c.Parent_TypeDef = t.Id
  JOIN MemberRef r ON c.Type_MemberRef = r.Id
  JOIN TypeDef g ON r.Class_TypeDef = g.Id
WHERE
  g.TypeNamespace = 'Windows.Win32.Foundation.Metadata'
  AND g.TypeName = 'GuidAttribute'
  AND t.Id = :parent
