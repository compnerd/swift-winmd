-- The render seed: the interface `TypeDef` rows to render, a name-filtered raw
-- scan rather than the `interfaces` view. The view INNER-joins each interface's
-- `GuidAttribute` across a three-way UNION over the whole `CustomAttribute`
-- table, so the `:name` predicate does not push into it: selecting one
-- interface still GUID-decodes every interface before filtering, and rendering
-- one pays the cost of decoding all of them. This scan seeks the interface
-- `TypeDef` rows directly (the `tdInterface` flag, bit 5) and the render fetches
-- each `iid` through the seekable `guid` query keyed by the interface's `Id`, so
-- rendering one interface no longer materialises the whole view.
--
-- The `iid` is not projected here: the render fetches it per interface and
-- drops an interface whose `guid` resolves nothing, reproducing the view's
-- INNER-join membership (a `tdInterface` `TypeDef` with no decodable
-- `GuidAttribute` is absent from the view and is therefore not rendered).
-- `ORDER BY Id` matches the ascending-`Id` row order the `interfaces` view
-- yields, so the emitted set and its order stay byte-identical.
-- This seed's schema is deliberately three columns (`Id`, `TypeNamespace`,
-- `TypeName`): the render fetches each `iid` through the seekable `guid`
-- query, not a four-column `interfaces`-view row. It is an intentional
-- performance change from the view-based seed — a caller overriding this
-- file must match the three-column schema (a fourth `iid` column is not
-- read).
--
SELECT
  Id,
  TypeNamespace,
  TypeName
FROM
  TypeDef
WHERE
  BITAND(Flags, 32) = 32
  AND (TypeName = :name OR '*' = :name)
ORDER BY
  Id
