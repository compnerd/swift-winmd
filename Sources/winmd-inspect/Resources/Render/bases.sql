-- The interface's plain (non-generic) bases, projected raw for the render to
-- spell in Swift: a TypeRef/TypeDef base carries its `base` TypeName
-- (keyword-escaped at render time, the way the interface's own name is) with a
-- NULL `spec`. A generic base is named through a TypeSpec, whose non-NULL
-- `spec` the `bases` view still resolves for queries; the render omits it
-- (`spec IS NULL`) because projecting WinRT generic-interface inheritance into
-- valid Swift is a deferred redesign — a generic definition's TypeName carries
-- an invalid arity suffix and a Swift protocol cannot refine the wrapper the
-- decoded spelling names.
SELECT
  base
FROM
  bases
WHERE
  spec IS NULL
