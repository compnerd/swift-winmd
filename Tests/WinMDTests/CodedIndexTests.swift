// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import XCTest
@testable import WinMD

extension CodedIndex {
  fileprivate static var discriminatorBitWidth: Int {
    Self.mask.nonzeroBitCount
  }
}

final class CodedIndexTest: XCTestCase {
  func testCodedIndexWidths() {
    XCTAssertEqual(TypeDefOrRef.discriminatorBitWidth, 2)
    XCTAssertEqual(HasConstant.discriminatorBitWidth, 2)
    XCTAssertEqual(HasCustomAttribute.discriminatorBitWidth, 5)
    XCTAssertEqual(HasFieldMarshal.discriminatorBitWidth, 1)
    XCTAssertEqual(HasDeclSecurity.discriminatorBitWidth, 2)
    XCTAssertEqual(MemberRefParent.discriminatorBitWidth, 3)
    XCTAssertEqual(HasSemantics.discriminatorBitWidth, 1)
    XCTAssertEqual(MethodDefOrRef.discriminatorBitWidth, 1)
    XCTAssertEqual(MemberForwarded.discriminatorBitWidth, 1)
    XCTAssertEqual(Implementation.discriminatorBitWidth, 2)
    XCTAssertEqual(CustomAttributeType.discriminatorBitWidth, 3)
    XCTAssertEqual(ResolutionScope.discriminatorBitWidth, 2)
    XCTAssertEqual(TypeOrMethodDef.discriminatorBitWidth, 1)
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
