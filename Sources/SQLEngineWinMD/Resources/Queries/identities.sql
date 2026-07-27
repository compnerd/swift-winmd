CREATE VIEW identities AS
  SELECT 'TypeDef' AS kind, Id, TypeNamespace, TypeName FROM TypeDef
  UNION ALL
  SELECT 'TypeRef' AS kind, Id, TypeNamespace, TypeName FROM TypeRef
  UNION ALL
  -- A TypeSpec (ECMA-335 §II.22.39) names a constructed type through a single
  -- Signature blob, not a TypeName; a generic instantiation
  -- (GENERICINST <base> <args…>) resolves to the identity of its generic base.
  -- The adapter decodes that base to the Base_TypeRef/Base_TypeDef keys — the
  -- 1-based Id of the base type in its table — so the base resolves against the
  -- base tables directly, the way `types` resolves Extends. A non-generic
  -- TypeSpec (a pointer, array, …) leaves both keys null and so names no
  -- identity row.
  SELECT 'TypeSpec' AS kind, ts.Id, r.TypeNamespace, r.TypeName
  FROM TypeSpec ts JOIN TypeRef r ON ts.Base_TypeRef = r.Id
  UNION ALL
  SELECT 'TypeSpec' AS kind, ts.Id, d.TypeNamespace, d.TypeName
  FROM TypeSpec ts JOIN TypeDef d ON ts.Base_TypeDef = d.Id
