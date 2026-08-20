// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

extension Metadata {
  public enum Tables {
  }
}

/// The case-insensitive fold that keys the name registry — Foundation's
/// case-folding (e.g. `ſ` folds to `s`), matching the `caseInsensitiveCompare`
/// the by-name scan used before, so a delimited relation name resolves the same.
private func folded(_ name: String) -> String {
  name.folding(options: .caseInsensitive, locale: nil)
}

extension Metadata.Tables {
  /// The CIL table number a schema named `name` carries (case-insensitively),
  /// or `nil` for a name no registered table bears.
  ///
  /// A once-built, reflection-free name resolution. The registry's schema names
  /// are reflected through `String(describing:)` a single time to seed
  /// `registry`, so a caller resolving a relation by name — the SQL adapter's
  /// `table(named:)`, hit tens of thousands of times over a query — consults a
  /// hashed lookup rather than reflecting every open table's schema per call.
  /// The map is schema-universal (a table's number does not vary by database),
  /// so it lives as a module-level `let`, not on a borrowed value.
  package static func number(named name: String) -> Int? {
    registry[folded(name)]
  }
}

/// The case-folded schema name → CIL table number map, built once over the
/// registered tables. The one place `String(describing:)` reflects a schema
/// name; every by-name resolution reads this hashed map thereafter. Keying on
/// `folded` (not `lowercased`) preserves the case-insensitive contract for a
/// Unicode case-fold equivalent — e.g. a delimited `"Typeſpec"` resolves to
/// `TypeSpec` because `ſ` folds to `s`, which `lowercased()` leaves unchanged.
private let registry: Dictionary<String, Int> = {
  var registry =
      Dictionary<String, Int>(minimumCapacity: kRegisteredTables.count)
  for schema in kRegisteredTables {
    registry[folded("\(schema)")] = schema.number
  }
  return registry
}()

@usableFromInline
internal let kRegisteredTables: Array<TableSchema.Type> = [
  Metadata.Tables.Assembly.self,
  Metadata.Tables.AssemblyOS.self,
  Metadata.Tables.AssemblyProcessor.self,
  Metadata.Tables.AssemblyRef.self,
  Metadata.Tables.AssemblyRefOS.self,
  Metadata.Tables.AssemblyRefProcessor.self,
  Metadata.Tables.ClassLayout.self,
  Metadata.Tables.Constant.self,
  Metadata.Tables.CustomAttribute.self,
  Metadata.Tables.DeclSecurity.self,
  Metadata.Tables.EventMap.self,
  Metadata.Tables.EventDef.self,
  Metadata.Tables.ExportedType.self,
  Metadata.Tables.FieldDef.self,
  Metadata.Tables.FieldLayout.self,
  Metadata.Tables.FieldMarshal.self,
  Metadata.Tables.FieldRVA.self,
  Metadata.Tables.File.self,
  Metadata.Tables.GenericParam.self,
  Metadata.Tables.GenericParamConstraint.self,
  Metadata.Tables.ImplMap.self,
  Metadata.Tables.InterfaceImpl.self,
  Metadata.Tables.ManifestResource.self,
  Metadata.Tables.MemberRef.self,
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MethodImpl.self,
  Metadata.Tables.MethodSemantics.self,
  Metadata.Tables.MethodSpec.self,
  Metadata.Tables.Module.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.NestedClass.self,
  Metadata.Tables.Param.self,
  Metadata.Tables.PropertyDef.self,
  Metadata.Tables.PropertyMap.self,
  Metadata.Tables.StandAloneSig.self,
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.TypeSpec.self,
].sorted(by: { $0.number < $1.number })
