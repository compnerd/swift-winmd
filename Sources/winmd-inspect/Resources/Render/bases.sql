-- The interface's plain (non-generic) base names, projected raw for the render
-- to spell in Swift (keyword-escaped at render time, the way the interface's own
-- name is). A generic base is named through a TypeSpec, whose non-NULL `spec`
-- the `bases` view still resolves for queries; the render omits it
-- (`spec IS NULL`) because projecting WinRT generic-interface inheritance into
-- valid Swift is a deferred redesign — a generic definition's TypeName carries
-- an invalid arity suffix and a Swift protocol cannot refine the wrapper the
-- decoded spelling names. The render resolves the selected base to its local
-- definition (spelling a nested one through its enclosing path) separately,
-- through the `requires` scope-chain walk, so this projects only the name.
SELECT
  base
FROM
  bases
WHERE
  spec IS NULL
