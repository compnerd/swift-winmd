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

  func testDebugDescription() {
    XCTAssertEqual(TypeDefOrRef(rawValue: 909).debugDescription,
                   "TypeRef Row 227")
  }
}
