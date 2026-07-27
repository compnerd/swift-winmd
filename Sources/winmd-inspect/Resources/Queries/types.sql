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
  TypeDef t
  LEFT JOIN identities r ON t.Extends_TypeRef = r.Id AND r.kind = 'TypeRef'
  LEFT JOIN identities d ON t.Extends_TypeDef = d.Id AND d.kind = 'TypeDef'
WHERE
  -- The first TypeDef is the ECMA-335 `<Module>` pseudo-type (the container for
  -- module-scope functions and variables): no base and no interface flag, so
  -- the classification would mislabel it a `class`. Exclude it by its reserved
  -- name so a caller enumerating declarations never sees it.
  t.TypeName <> '<Module>'
