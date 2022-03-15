// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata {
  public enum Tables {
  }
}

@usableFromInline
internal var kRegisteredTables: [Table.Type] = [
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
