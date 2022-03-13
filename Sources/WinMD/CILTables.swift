// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata {
  public enum Tables {
  }
}

extension Metadata.Tables {
  static func forEach(_ body: (Table.Type) throws -> Void) rethrows {
    try [
      Assembly.self,
      AssemblyOS.self,
      AssemblyProcessor.self,
      AssemblyRef.self,
      AssemblyRefOS.self,
      AssemblyRefProcessor.self,
      ClassLayout.self,
      Constant.self,
      CustomAttribute.self,
      DeclSecurity.self,
      EventMap.self,
      EventDef.self,
      ExportedType.self,
      FieldDef.self,
      FieldLayout.self,
      FieldMarshal.self,
      FieldRVA.self,
      File.self,
      GenericParam.self,
      GenericParamConstraint.self,
      ImplMap.self,
      InterfaceImpl.self,
      ManifestResource.self,
      MemberRef.self,
      MethodDef.self,
      MethodImpl.self,
      MethodSemantics.self,
      MethodSpec.self,
      Module.self,
      ModuleRef.self,
      NestedClass.self,
      Param.self,
      PropertyDef.self,
      PropertyMap.self,
      StandAloneSig.self,
      TypeDef.self,
      TypeRef.self,
      TypeSpec.self,
    ].sorted(by: { $0.number < $1.number }).forEach(body)
  }
}
