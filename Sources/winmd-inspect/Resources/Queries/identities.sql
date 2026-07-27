CREATE VIEW identities AS
  SELECT 'TypeDef' AS kind, Id, TypeNamespace, TypeName FROM TypeDef
  UNION ALL
  SELECT 'TypeRef' AS kind, Id, TypeNamespace, TypeName FROM TypeRef
