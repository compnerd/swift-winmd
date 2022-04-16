// Copyright (c) 2021 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3

import XCTest
@testable import WinMD

extension CodedIndex {
  fileprivate static var descriminatorBitWidth: Int {
    Self.mask.nonzeroBitCount
  }
}

final class CodedIndexTest: XCTestCase {
  func testCodedIndexWidths() {
    XCTAssertEqual(TypeDefOrRef.descriminatorBitWidth, 2)
    XCTAssertEqual(HasConstant.descriminatorBitWidth, 2)
    XCTAssertEqual(HasCustomAttribute.descriminatorBitWidth, 5)
    XCTAssertEqual(HasFieldMarshal.descriminatorBitWidth, 1)
    XCTAssertEqual(HasDeclSecurity.descriminatorBitWidth, 2)
    XCTAssertEqual(MemberRefParent.descriminatorBitWidth, 3)
    XCTAssertEqual(HasSemantics.descriminatorBitWidth, 1)
    XCTAssertEqual(MethodDefOrRef.descriminatorBitWidth, 1)
    XCTAssertEqual(MemberForwarded.descriminatorBitWidth, 1)
    XCTAssertEqual(Implementation.descriminatorBitWidth, 2)
    XCTAssertEqual(CustomAttributeType.descriminatorBitWidth, 3)
    XCTAssertEqual(ResolutionScope.descriminatorBitWidth, 2)
    XCTAssertEqual(TypeOrMethodDef.descriminatorBitWidth, 1)
  }

  func testTypeDefOrRef() {
    let index = TypeDefOrRef(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 227)
    XCTAssertEqual(index.debugDescription, "TypeRef Row 227")
  }

  func testHasConstant() {
    let index = HasConstant(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 227)
    XCTAssertEqual(index.debugDescription, "Param Row 227")
  }

  func testHasCustomAttribute() {
    let index = HasCustomAttribute(rawValue: 909)
    XCTAssertEqual(index.tag, 13)
    XCTAssertEqual(index.row, 28)
    XCTAssertEqual(index.debugDescription, "TypeSpec Row 28")
  }

  func testHasFieldMarshall() {
    let index = HasFieldMarshal(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 454)
    XCTAssertEqual(index.debugDescription, "Param Row 454")
  }

  func testHasDeclSecurity() {
    let index = HasDeclSecurity(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 227)
    XCTAssertEqual(index.debugDescription, "MethodDef Row 227")
  }

  func testMemberRefParent() {
    let index = MemberRefParent(rawValue: 908)
    XCTAssertEqual(index.tag, 4)
    XCTAssertEqual(index.row, 113)
    XCTAssertEqual(index.debugDescription, "TypeSpec Row 113")
  }

  func testHasSemantics() {
    let index = HasSemantics(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 454)
    XCTAssertEqual(index.debugDescription, "PropertyDef Row 454")
  }

  func testMethodDefOrRef() {
    let index = MethodDefOrRef(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 454)
    XCTAssertEqual(index.debugDescription, "MemberRef Row 454")
  }

  func testMemberForwarded() {
    let index = MemberForwarded(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 454)
    XCTAssertEqual(index.debugDescription, "MethodDef Row 454")
  }

  func testImplementation() {
    let index = Implementation(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 227)
    XCTAssertEqual(index.debugDescription, "AssemblyRef Row 227")
  }

  func testCustomAttributeType() {
    let index = CustomAttributeType(rawValue: 906)
    XCTAssertEqual(index.tag, 2)
    XCTAssertEqual(index.row, 113)
    XCTAssertEqual(index.debugDescription, "MethodDef Row 113")
  }

  func testResolutionScope() {
    let index = ResolutionScope(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 227)
    XCTAssertEqual(index.debugDescription, "ModuleRef Row 227")
  }

  func testTypeOrMethodDef() {
    let index = TypeOrMethodDef(rawValue: 909)
    XCTAssertEqual(index.tag, 1)
    XCTAssertEqual(index.row, 454)
    XCTAssertEqual(index.debugDescription, "MethodDef Row 454")
  }
}
