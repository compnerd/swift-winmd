-- A delegate's `Invoke` method, through the `methods` view bound by the
-- delegate's `Id`. A WinRT delegate is a `TypeDef` whose signature lives on its
-- `Invoke` method (its `.ctor` aside); selecting that one method's `Id` gives
-- the render the signature to decode as the delegate's parameters and return
-- (edge E7), the same way an interface method is decoded.
SELECT
  Id
FROM
  methods
WHERE
  Name = 'Invoke'
