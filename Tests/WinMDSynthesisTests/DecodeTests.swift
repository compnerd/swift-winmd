// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMDSynthesis
@testable import WinMD

struct DecodeTests {
  // A resolver that resolves nothing; the pure cases never consult it, and the
  // named cases are exercised end-to-end by the synthesizer's golden tests.
  private var resolver: Resolver { Resolver([:]) }

  @Test("a primitive decodes to its C typealias spelling")
  func primitives() {
    let cases: Array<(PrimitiveType, String)> = [
      (.void, "Void"),
      (.boolean, "CBool"),
      (.char, "Unicode.UTF16.CodeUnit"),
      (.int1, "CChar"),
      (.uint1, "CUnsignedChar"),
      (.int4, "CInt"),
      (.uint4, "CUnsignedInt"),
      (.int8, "CLongLong"),
      (.uint8, "CUnsignedLongLong"),
      (.double, "CDouble"),
      (.intptr, "Int"),
      (.uintptr, "UInt"),
      // `ELEMENT_TYPE_STRING` is the WinRT `String` — an `HSTRING` handle, not
      // a `PCWSTR` buffer (which arrives as pointer/named metadata).
      (.string, "HSTRING"),
    ]
    for (primitive, spelling) in cases {
      #expect(SignatureType.primitive(primitive).decode(with: resolver)
                  == spelling)
    }
  }

  @Test("a pointer wraps its decoded pointee")
  func pointers() {
    #expect(SignatureType.pointer(.primitive(.void)).decode(with: resolver)
                == "UnsafeMutableRawPointer")
    #expect(SignatureType.pointer(.primitive(.int4)).decode(with: resolver)
                == "UnsafeMutablePointer<CInt>")
    #expect(SignatureType.pointer(.pointer(.primitive(.void)))
                .decode(with: resolver)
                == "UnsafeMutablePointer<UnsafeMutableRawPointer?>")
    // A UTF-16 buffer (a `PWSTR`-shaped char pointer) stays a pointer — the
    // `HSTRING` mapping is for `ELEMENT_TYPE_STRING`, not for char pointers.
    #expect(SignatureType.pointer(.primitive(.char)).decode(with: resolver)
                == "UnsafeMutablePointer<Unicode.UTF16.CodeUnit>")
  }

  @Test("a generic variable decodes to a T/M-prefixed placeholder")
  func variables() {
    #expect(SignatureType.variable(scope: .type, 0).decode(with: resolver)
                == "T0")
    #expect(SignatureType.variable(scope: .method, 2).decode(with: resolver)
                == "M2")
  }

  @Test("only an IsConst custom modifier marks a pointee const")
  func modifiers() {
    // Two modifier-type references: one resolves to `IsConst`, the other to an
    // unrelated type. Only the former may flip the pointer to immutable.
    let marker = TypeDefOrRef(rawValue: 1)
    let other = TypeDefOrRef(rawValue: 2)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
      other.rawValue: Identity(namespace: "Windows.Win32.Foundation",
                               name: "BOOL"),
    ])

    // `*modopt(IsConst) int` decodes to a `const` pointer.
    let immutable = SignatureType.modified(.primitive(.int4),
        modifiers: [Modifier(required: false, type: marker)])
    #expect(SignatureType.pointer(immutable).decode(with: resolver)
                == "UnsafePointer<CInt>")

    // A non-`IsConst` modifier leaves the pointer mutable.
    let mutable = SignatureType.modified(.primitive(.int4),
        modifiers: [Modifier(required: false, type: other)])
    #expect(SignatureType.pointer(mutable).decode(with: resolver)
                == "UnsafeMutablePointer<CInt>")
  }

  @Test("a generic instantiation strips the CLR arity from its base name")
  func genericInstance() {
    let reference = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      reference.rawValue: Identity(namespace: "Windows.Foundation",
                                   name: "IReference`1"),
    ])

    // `IReference`1<int>` composes the Swift generic without the arity suffix.
    let instance = SignatureType.instance(.named(kind: .class, reference),
                                          [.primitive(.int4)])
    #expect(instance.decode(with: resolver) == "IReference<CInt>")
  }

  @Test("a generic over an unresolved base degrades to the opaque pointer")
  func unresolvedGenericBase() {
    // The base reference resolves to nothing (e.g. a TypeSpec with no
    // identity): the empty resolver leaves it unresolved.
    let base = TypeDefOrRef(rawValue: 1)
    let instance = SignatureType.instance(.named(kind: .class, base),
                                          [.primitive(.int4)])
    #expect(instance.decode(with: Resolver([:])) == "UnsafeMutableRawPointer")
  }

  @Test("a generic argument keeps the parameter-name class-ID hint")
  func genericArgumentHint() {
    let base = TypeDefOrRef(rawValue: 1)
    let guid = TypeDefOrRef(rawValue: 2)
    let resolver = Resolver([
      base.rawValue: Identity(namespace: "Windows.Foundation",
                              name: "IReference`1"),
      guid.rawValue: Identity(namespace: "System", name: "Guid"),
    ])
    let reference = SignatureType.instance(.named(kind: .class, base),
                                           [.named(kind: .value, guid)])

    // The `clsid` hint reaches the `System.Guid` argument…
    #expect(reference.decode(parameter: "clsid", with: resolver)
                == "IReference<CLSID>")
    // …and absent a hint it defaults to `IID`.
    #expect(reference.decode(with: resolver) == "IReference<IID>")
  }

  @Test("a non-void pointer-to-pointer keeps the optional inner slot")
  func doublePointer() {
    let marker = TypeDefOrRef(rawValue: 1)
    let foo = TypeDefOrRef(rawValue: 2)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
    ])

    // `int **` → pointer to an *optional* mutable pointer.
    #expect(SignatureType.pointer(.pointer(.primitive(.int4)))
                .decode(with: resolver)
                == "UnsafeMutablePointer<UnsafeMutablePointer<CInt>?>")

    // `const int **` → the inner pointer is immutable, the slot still optional.
    let constInt = SignatureType.pointer(.pointer(
        .modified(.primitive(.int4),
                  modifiers: [Modifier(required: false, type: marker)])))
    #expect(constInt.decode(with: resolver)
                == "UnsafeMutablePointer<UnsafePointer<CInt>?>")

    // `IFoo **` → pointer to an *optional* typed pointer.
    #expect(SignatureType.pointer(.pointer(.named(kind: .class, foo)))
                .decode(with: resolver)
                == "UnsafeMutablePointer<UnsafeMutablePointer<IFoo>?>")
  }

  @Test("a const void-pointer pointee honors const")
  func constVoidPointer() {
    let marker = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
    ])

    // `void * const *` decodes to a pointer to an immutable raw pointer.
    let immutable = SignatureType.modified(.pointer(.primitive(.void)),
        modifiers: [Modifier(required: false, type: marker)])
    #expect(SignatureType.pointer(immutable).decode(with: resolver)
                == "UnsafePointer<UnsafeMutableRawPointer?>")
  }

  @Test("a pointer to a const void pointer keeps the optional raw slot")
  func constVoidPointerPointee() {
    let marker = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
    ])

    // `const void **` is a pointer to an *optional* const raw pointer; the
    // optionality must survive the const modifier on the inner void.
    let inner = SignatureType.pointer(
        .modified(.primitive(.void),
                  modifiers: [Modifier(required: false, type: marker)]))
    #expect(SignatureType.pointer(inner).decode(with: resolver)
                == "UnsafeMutablePointer<UnsafeRawPointer?>")
  }
}
