// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

extension CodedIndex {
  fileprivate static var discriminatorBitWidth: Int {
    Self.mask.nonzeroBitCount
  }
}

struct CodedIndexTests {
  @Test("each coded index has the expected tag bit width")
  func widths() {
    #expect(TypeDefOrRef.discriminatorBitWidth == 2)
    #expect(HasConstant.discriminatorBitWidth == 2)
    #expect(HasCustomAttribute.discriminatorBitWidth == 5)
    #expect(HasFieldMarshal.discriminatorBitWidth == 1)
    #expect(HasDeclSecurity.discriminatorBitWidth == 2)
    #expect(MemberRefParent.discriminatorBitWidth == 3)
    #expect(HasSemantics.discriminatorBitWidth == 1)
    #expect(MethodDefOrRef.discriminatorBitWidth == 1)
    #expect(MemberForwarded.discriminatorBitWidth == 1)
    #expect(Implementation.discriminatorBitWidth == 2)
    #expect(CustomAttributeType.discriminatorBitWidth == 3)
    #expect(ResolutionScope.discriminatorBitWidth == 2)
    #expect(TypeOrMethodDef.discriminatorBitWidth == 1)
  }

  @Test("splits a TypeDefOrRef into tag and row")
  func typeDefOrRef() {
    let index = TypeDefOrRef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "TypeRef Row 227")
  }

  @Test("splits a HasConstant into tag and row")
  func hasConstant() {
    let index = HasConstant(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "Param Row 227")
  }

  @Test("splits a HasCustomAttribute into tag and row")
  func hasCustomAttribute() {
    let index = HasCustomAttribute(rawValue: 909)
    #expect(index.tag == 13)
    #expect(index.row == 28)
    #expect(index.debugDescription == "TypeSpec Row 28")
  }

  @Test("splits a HasFieldMarshal into tag and row")
  func hasFieldMarshal() {
    let index = HasFieldMarshal(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "Param Row 454")
  }

  @Test("splits a HasDeclSecurity into tag and row")
  func hasDeclSecurity() {
    let index = HasDeclSecurity(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "MethodDef Row 227")
  }

  @Test("splits a MemberRefParent into tag and row")
  func memberRefParent() {
    let index = MemberRefParent(rawValue: 908)
    #expect(index.tag == 4)
    #expect(index.row == 113)
    #expect(index.debugDescription == "TypeSpec Row 113")
  }

  @Test("splits a HasSemantics into tag and row")
  func hasSemantics() {
    let index = HasSemantics(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "PropertyDef Row 454")
  }

  @Test("splits a MethodDefOrRef into tag and row")
  func methodDefOrRef() {
    let index = MethodDefOrRef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MemberRef Row 454")
  }

  @Test("splits a MemberForwarded into tag and row")
  func memberForwarded() {
    let index = MemberForwarded(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MethodDef Row 454")
  }

  @Test("splits an Implementation into tag and row")
  func implementation() {
    let index = Implementation(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "AssemblyRef Row 227")
  }

  @Test("splits a CustomAttributeType into tag and row")
  func customAttributeType() {
    let index = CustomAttributeType(rawValue: 906)
    #expect(index.tag == 2)
    #expect(index.row == 113)
    #expect(index.debugDescription == "MethodDef Row 113")
  }

  @Test("splits a ResolutionScope into tag and row")
  func resolutionScope() {
    let index = ResolutionScope(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "ModuleRef Row 227")
  }

  @Test("splits a TypeOrMethodDef into tag and row")
  func typeOrMethodDef() {
    let index = TypeOrMethodDef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MethodDef Row 454")
  }
}
