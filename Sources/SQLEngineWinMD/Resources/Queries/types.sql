CREATE VIEW types AS
SELECT
  t.Id,
  t.TypeNamespace,
  t.TypeName,
  CASE
    WHEN BITAND(t.Flags, 32) = 32 THEN 'interface'
    WHEN COALESCE(r.TypeNamespace, d.TypeNamespace) = 'System'
         AND COALESCE(r.TypeName, d.TypeName) = 'Enum' THEN 'enum'
    WHEN COALESCE(r.TypeNamespace, d.TypeNamespace) = 'System'
         AND COALESCE(r.TypeName, d.TypeName) = 'MulticastDelegate'
         THEN 'delegate'
    WHEN COALESCE(r.TypeNamespace, d.TypeNamespace) = 'System'
         AND COALESCE(r.TypeName, d.TypeName) = 'ValueType' THEN 'struct'
    ELSE 'class'
  END AS kind,
  COALESCE(r.TypeNamespace, d.TypeNamespace) AS base_namespace,
  COALESCE(r.TypeName, d.TypeName) AS base_name
FROM
  -- `Extends_TypeRef`/`Extends_TypeDef` are the 1-based Id of the base type in
  -- its own table, so the base resolves by a seekable join against the TypeRef
  -- and TypeDef base tables directly. The `identities` view's TypeRef and
  -- TypeDef arms are exactly `SELECT … FROM TypeRef`/`… FROM TypeDef`, so the
  -- COALESCE and CASE below read the same namespace and name they would have
  -- through that view -- but without re-evaluating a four-way UNION per row.
  TypeDef t
  LEFT JOIN TypeRef r ON t.Extends_TypeRef = r.Id
  LEFT JOIN TypeDef d ON t.Extends_TypeDef = d.Id
WHERE
  -- The first TypeDef is the ECMA-335 `<Module>` pseudo-type (the container for
  -- module-scope functions and variables): no base and no interface flag, so
  -- the classification would mislabel it a `class`. Exclude it by its reserved
  -- name so a caller enumerating declarations never sees it.
  t.TypeName <> '<Module>'
