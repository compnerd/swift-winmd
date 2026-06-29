// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMDSynthesis
@testable import WinMD

// `Tuple.identity` reads a type's `Namespace.Name` by resolved ordinal
// off a type-erased `Tuple`; a `TypeRef` carries both, a table without them
// yields `nil`.
struct IdentityTests {
  // A `#Strings` heap: "\0System\0Guid\0".
  private static let strings: Array<UInt8> = [
    0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x00,
  ]

  // A single `TypeRef`: ResolutionScope 0, TypeName = "Guid" (offset 8),
  // TypeNamespace = "System" (offset 1).
  private static let record: Array<UInt8> = [
    0x00, 0x00, 0x08, 0x00, 0x01, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
          wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = (1 << 1)

  // A `TypeRef` whose `TypeName` offset (0xFF) points past the `#Strings` heap,
  // so reading the name throws `.BadImageFormat`.
  private static let malformed: Array<UInt8> = [
    0x00, 0x00, 0xFF, 0x00, 0x01, 0x00,
  ]

  @Test("reads a TypeRef's namespace and name as an Identity")
  func typeRefIdentity() throws {
    let storage = Storage(bytes: IdentityTests.record.span.bytes,
                          relations: IdentityTests.relations.span,
                          strings: IdentityTests.strings.span.bytes,
                          blob: IdentityTests.empty.span.bytes,
                          guid: IdentityTests.empty.span.bytes,
                          valid: IdentityTests.valid, sorted: 0)
    let tuple = Tuple(0, IdentityTests.relations[0], storage)
    let identity = try tuple.identity
    #expect(identity == Identity(namespace: "System", name: "Guid"))
  }

  @Test("a malformed name offset propagates a WinMDError")
  func malformedIdentity() {
    let storage = Storage(bytes: IdentityTests.malformed.span.bytes,
                          relations: IdentityTests.relations.span,
                          strings: IdentityTests.strings.span.bytes,
                          blob: IdentityTests.empty.span.bytes,
                          guid: IdentityTests.empty.span.bytes,
                          valid: IdentityTests.valid, sorted: 0)
    let tuple = Tuple(0, IdentityTests.relations[0], storage)
    #expect(throws: WinMDError.self) { _ = try tuple.identity }
  }
}
