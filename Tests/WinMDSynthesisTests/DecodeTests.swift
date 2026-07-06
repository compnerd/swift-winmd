// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMDSynthesis
@testable import WinMD

/// The Swift `Dialect` the decode tests spell against — the same strings the
/// bundled `swift.lang` carries, so the assertions read the exact Swift spellings
/// as before the decode was parameterised by a dialect.
extension Dialect {
  static var swift: Dialect {
    Dialect(
        primitives: [
          "void": "Void", "bool": "CBool", "char": "Unicode.UTF16.CodeUnit",
          "i1": "CChar", "u1": "CUnsignedChar", "i2": "CShort",
          "u2": "CUnsignedShort", "i4": "CInt", "u4": "CUnsignedInt",
          "i8": "CLongLong", "u8": "CUnsignedLongLong", "f4": "CFloat",
          "f8": "CDouble", "iptr": "Int", "uptr": "UInt", "string": "HSTRING",
          "object": "UnsafeMutableRawPointer",
          "typedref": "UnsafeMutableRawPointer",
        ],
        pointer: (typed: (mutable: "UnsafeMutablePointer",
                          constant: "UnsafePointer"),
                  untyped: (mutable: "UnsafeMutableRawPointer",
                            constant: "UnsafeRawPointer")),
        optional: "?",
        generic: (open: "<", close: ">"),
        variable: (type: "T", method: "M"),
        opaque: "UnsafeMutableRawPointer",
        guid: (iid: "IID", clsid: "CLSID"),
        known: [
          Identity(namespace: "Windows.Win32.Foundation", name: "HRESULT"):
              "HRESULT",
          Identity(namespace: "Windows.Win32.Foundation", name: "BOOL"):
              "BOOL",
        ],
        escape: { keyword in
          ["class", "default", "in", "protocol", "repeat"].contains(keyword)
              ? "`\(keyword)`" : keyword
        })
  }
}

struct DecodeTests {
  // A resolver that resolves nothing; the pure cases never consult it, and the
  // named cases are exercised end-to-end by the synthesizer's golden tests.
  private var resolver: Resolver { Resolver([:]) }

  // The Swift dialect every case spells against.
  private var dialect: Dialect { .swift }

  @Test func `a primitive decodes to its C typealias spelling`() {
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
      #expect(SignatureType.primitive(primitive)
                  .decode(with: resolver, dialect: dialect) == spelling)
    }
  }

  @Test func `a pointer wraps its decoded pointee`() {
    #expect(SignatureType.pointer(.primitive(.void))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutableRawPointer")
    #expect(SignatureType.pointer(.primitive(.int4))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<CInt>")
    #expect(SignatureType.pointer(.pointer(.primitive(.void)))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeMutableRawPointer?>")
    // A UTF-16 buffer (a `PWSTR`-shaped char pointer) stays a pointer — the
    // `HSTRING` mapping is for `ELEMENT_TYPE_STRING`, not for char pointers.
    #expect(SignatureType.pointer(.primitive(.char))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<Unicode.UTF16.CodeUnit>")
  }

  @Test func `a generic variable decodes to a T/M-prefixed placeholder`() {
    #expect(SignatureType.variable(scope: .type, 0)
                .decode(with: resolver, dialect: dialect) == "T0")
    #expect(SignatureType.variable(scope: .method, 2)
                .decode(with: resolver, dialect: dialect) == "M2")
  }

  @Test func `a type variable spells its declared name when names are supplied`() {
    // With the owner's ordered names threaded, a `VAR` spells the declared
    // parameter's name (`VAR 0` of `<Element>` → `Element`) rather than the
    // positional placeholder.
    #expect(SignatureType.variable(scope: .type, 0)
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "Element")
    #expect(SignatureType.variable(scope: .type, 1)
                .decode(generics: ["Key", "Value"], with: resolver,
                        dialect: dialect)
                == "Value")
    // An out-of-range operand falls back to the placeholder.
    #expect(SignatureType.variable(scope: .type, 2)
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "T2")
    // A method variable (`MVAR`) keeps its placeholder — only the type-level
    // names are threaded, so a method-level operand never indexes them.
    #expect(SignatureType.variable(scope: .method, 0)
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "M0")
  }

  @Test func `a negative type variable operand falls back to the placeholder`() {
    // The metadata decoder emits no negative operand, but the enum case and
    // `decode(generics:)` are public — a malformed programmatic `VAR -1` must
    // degrade to the positional placeholder rather than trap on `generics[-1]`,
    // exactly as an out-of-range operand does.
    #expect(SignatureType.variable(scope: .type, -1)
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "T-1")
  }

  @Test func `a nested type variable spells its declared name`() {
    // The names thread through the structural cases too: a `VAR` inside a
    // pointer or a `GENERICINST` argument spells the declared name.
    #expect(SignatureType.pointer(.variable(scope: .type, 0))
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<Element>")
    let base = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      base.rawValue: Identity(namespace: "Windows.Foundation",
                              name: "IReference`1"),
    ])
    #expect(SignatureType.instance(.named(kind: .class, base),
                                   [.variable(scope: .type, 0)])
                .decode(generics: ["Element"], with: resolver, dialect: dialect)
                == "IReference<Element>")
  }

  @Test func `a generic declaration clause wraps the ordered names`() {
    // The declaration hook composes the dialect's generic delimiters around the
    // comma-separated names; an empty list is a non-generic declaration (`nil`).
    #expect(dialect.generics(["Element"]) == "<Element>")
    #expect(dialect.generics(["Key", "Value"]) == "<Key, Value>")
    #expect(dialect.generics([]) == nil)
  }

  @Test func `a keyword-named type variable escapes its use and declaration`() {
    // A parameter whose metadata name is a Swift keyword (`in`, `class`) must
    // spell its `VAR` use through the dialect's keyword escape — a raw keyword
    // is an invalid type reference (`UnsafeMutablePointer<in>`). The escaped
    // spelling appears bare and inside the structural cases alike.
    #expect(SignatureType.variable(scope: .type, 0)
                .decode(generics: ["in"], with: resolver, dialect: dialect)
                == "`in`")
    #expect(SignatureType.pointer(.variable(scope: .type, 0))
                .decode(generics: ["in"], with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<`in`>")
    // The declaration clause escapes the same name, so declaration and use
    // agree — a `` `in` `` use resolves against a `` <`in`> `` declaration.
    #expect(dialect.generics(["in"]) == "<`in`>")
    #expect(dialect.generics(["class", "Value"]) == "<`class`, Value>")
  }

  @Test func `only an IsConst custom modifier marks a pointee const`() {
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
    #expect(SignatureType.pointer(immutable)
                .decode(with: resolver, dialect: dialect)
                == "UnsafePointer<CInt>")

    // A non-`IsConst` modifier leaves the pointer mutable.
    let mutable = SignatureType.modified(.primitive(.int4),
        modifiers: [Modifier(required: false, type: other)])
    #expect(SignatureType.pointer(mutable)
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<CInt>")
  }

  @Test func `a generic instantiation strips the CLR arity from its base name`() {
    let reference = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      reference.rawValue: Identity(namespace: "Windows.Foundation",
                                   name: "IReference`1"),
    ])

    // `IReference`1<int>` composes the Swift generic without the arity suffix.
    let instance = SignatureType.instance(.named(kind: .class, reference),
                                          [.primitive(.int4)])
    #expect(instance.decode(with: resolver, dialect: dialect)
                == "IReference<CInt>")
  }

  @Test func `a generic over an unresolved base degrades to the opaque pointer`() {
    // The base reference resolves to nothing (e.g. a TypeSpec with no
    // identity): the empty resolver leaves it unresolved.
    let base = TypeDefOrRef(rawValue: 1)
    let instance = SignatureType.instance(.named(kind: .class, base),
                                          [.primitive(.int4)])
    #expect(instance.decode(with: Resolver([:]), dialect: dialect)
                == "UnsafeMutableRawPointer")
  }

  @Test func `a named type whose simple name is a keyword is escaped`() {
    // A metadata type whose simple name collides with a target keyword
    // (`protocol`, `repeat`, …) spells escaped, like a declaration name, so a
    // parameter or return of that type still compiles.
    let reference = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      reference.rawValue: Identity(namespace: "NS", name: "protocol"),
    ])
    #expect(SignatureType.named(kind: .class, reference)
                .decode(with: resolver, dialect: dialect) == "`protocol`")
  }

  @Test func `a generic base is escaped after its CLR arity is stripped`() {
    // The generic definition's name carries the arity suffix (`protocol``1`),
    // so it matches no keyword until the suffix is stripped; the base must be
    // escaped after the strip, not before, or it spells `protocol<CInt>`.
    let base = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      base.rawValue: Identity(namespace: "NS", name: "protocol`1"),
    ])
    let instance = SignatureType.instance(.named(kind: .class, base),
                                          [.primitive(.int4)])
    #expect(instance.decode(with: resolver, dialect: dialect)
                == "`protocol`<CInt>")
  }

  @Test func `a generic argument keeps the parameter-name class-ID hint`() {
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
    #expect(reference.decode(parameter: "clsid", with: resolver,
                             dialect: dialect)
                == "IReference<CLSID>")
    // …and absent a hint it defaults to `IID`.
    #expect(reference.decode(with: resolver, dialect: dialect)
                == "IReference<IID>")
  }

  @Test func `a non-void pointer-to-pointer keeps the optional inner slot`() {
    let marker = TypeDefOrRef(rawValue: 1)
    let foo = TypeDefOrRef(rawValue: 2)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
    ])

    // `int **` → pointer to an *optional* mutable pointer.
    #expect(SignatureType.pointer(.pointer(.primitive(.int4)))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeMutablePointer<CInt>?>")

    // `const int **` → the inner pointer is immutable, the slot still optional.
    let constInt = SignatureType.pointer(.pointer(
        .modified(.primitive(.int4),
                  modifiers: [Modifier(required: false, type: marker)])))
    #expect(constInt.decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafePointer<CInt>?>")

    // `IFoo **` → pointer to an *optional* typed pointer.
    #expect(SignatureType.pointer(.pointer(.named(kind: .class, foo)))
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeMutablePointer<IFoo>?>")
  }

  @Test func `a const void-pointer pointee honors const`() {
    let marker = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
    ])

    // `void * const *` decodes to a pointer to an immutable raw pointer.
    let immutable = SignatureType.modified(.pointer(.primitive(.void)),
        modifiers: [Modifier(required: false, type: marker)])
    #expect(SignatureType.pointer(immutable)
                .decode(with: resolver, dialect: dialect)
                == "UnsafePointer<UnsafeMutableRawPointer?>")
  }

  @Test func `a pointer to a const void pointer keeps the optional raw slot`() {
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
    #expect(SignatureType.pointer(inner)
                .decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeRawPointer?>")
  }
}
