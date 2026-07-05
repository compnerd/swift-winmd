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
  @Test func `each coded index has the expected tag bit width`() {
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

  @Test func `derives tag width from the table count, not its popcount`() {
    // `PhysicalSchema.width(of:)` selects the coded-index width from the tag
    // width. It once derived that from the population count of the table count,
    // which is only `ceil(log2(n))` when `n` is a power of two; for the others
    // it under-counted and over-sized the compressed range, mis-selecting a
    // 2-byte index where 4 are required. Pin the diverging cases.
    #expect(TypeDefOrRef.bits == 2)        // 3 tables; popcount(2) is 1
    #expect(MemberRefParent.bits == 3)     // 5 tables; popcount(4) is 1
    #expect(HasCustomAttribute.bits == 5)  // 22 tables; popcount(21) is 3
  }

  @Test func `splits a TypeDefOrRef into tag and row`() {
    let index = TypeDefOrRef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "TypeRef Row 227")
  }

  @Test func `splits a HasConstant into tag and row`() {
    let index = HasConstant(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "Param Row 227")
  }

  @Test func `splits a HasCustomAttribute into tag and row`() {
    let index = HasCustomAttribute(rawValue: 909)
    #expect(index.tag == 13)
    #expect(index.row == 28)
    #expect(index.debugDescription == "TypeSpec Row 28")
  }

  @Test func `splits a HasFieldMarshal into tag and row`() {
    let index = HasFieldMarshal(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "Param Row 454")
  }

  @Test func `splits a HasDeclSecurity into tag and row`() {
    let index = HasDeclSecurity(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "MethodDef Row 227")
  }

  @Test func `splits a MemberRefParent into tag and row`() {
    let index = MemberRefParent(rawValue: 908)
    #expect(index.tag == 4)
    #expect(index.row == 113)
    #expect(index.debugDescription == "TypeSpec Row 113")
  }

  @Test func `splits a HasSemantics into tag and row`() {
    let index = HasSemantics(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "PropertyDef Row 454")
  }

  @Test func `splits a MethodDefOrRef into tag and row`() {
    let index = MethodDefOrRef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MemberRef Row 454")
  }

  @Test func `splits a MemberForwarded into tag and row`() {
    let index = MemberForwarded(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MethodDef Row 454")
  }

  @Test func `splits an Implementation into tag and row`() {
    let index = Implementation(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "AssemblyRef Row 227")
  }

  @Test func `splits a CustomAttributeType into tag and row`() {
    let index = CustomAttributeType(rawValue: 906)
    #expect(index.tag == 2)
    #expect(index.row == 113)
    #expect(index.debugDescription == "MethodDef Row 113")
  }

  @Test func `splits a ResolutionScope into tag and row`() {
    let index = ResolutionScope(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 227)
    #expect(index.debugDescription == "ModuleRef Row 227")
  }

  @Test func `splits a TypeOrMethodDef into tag and row`() {
    let index = TypeOrMethodDef(rawValue: 909)
    #expect(index.tag == 1)
    #expect(index.row == 454)
    #expect(index.debugDescription == "MethodDef Row 454")
  }
}
