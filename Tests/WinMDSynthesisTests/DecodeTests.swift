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

  // MARK: - ABI erasure

  @Test func `a class-kinded named type is a reference erased to a pointer`() {
    // A WinRT interface/class/delegate is `ELEMENT_TYPE_CLASS`: at the ABI it
    // erases to the interface pointer (the dialect's opaque raw pointer), not
    // its own `IFoo` spelling.
    let foo = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
    ])
    let type = SignatureType.named(kind: .class, foo)
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutableRawPointer")
    // Its own decoded spelling — what the erasure replaces — is the named type.
    #expect(type.decode(with: resolver, dialect: dialect) == "IFoo")
  }

  @Test func `a value-kinded named type is a value keeping its own spelling`() {
    // A `VALUETYPE` (a struct or enum) crosses the ABI as itself, so its ABI
    // spelling is its own decoded spelling.
    let point = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      point.rawValue: Identity(namespace: "Windows.Foundation", name: "Point"),
    ])
    let type = SignatureType.named(kind: .value, point)
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect) == "Point")
  }

  @Test func `a primitive is a value keeping its own ABI spelling`() {
    for primitive in [PrimitiveType.int4, .double, .boolean, .uintptr] {
      let type = SignatureType.primitive(primitive)
      #expect(type.classification == .value)
      #expect(type.abi(with: resolver, dialect: dialect)
                  == type.decode(with: resolver, dialect: dialect))
    }
  }

  @Test func `the WinRT string keeps HSTRING rather than erasing to a pointer`() {
    // `ELEMENT_TYPE_STRING` is a value-like handle (windows-rs `CloneType`), so
    // its ABI is the `HSTRING` handle — NOT the erased interface pointer an
    // object reference collapses to.
    let type = SignatureType.primitive(.string)
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect) == "HSTRING")
  }

  @Test func `the object primitive is a reference erased to a pointer`() {
    // `ELEMENT_TYPE_OBJECT` is `System.Object` — WinRT's `IInspectable`, an
    // object reference despite being a primitive element type; it erases to the
    // interface pointer, so its ABI is the dialect's opaque raw pointer.
    let type = SignatureType.primitive(.object)
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutableRawPointer")
  }

  @Test func `a typed reference is a value keeping its own ABI spelling`() {
    // `ELEMENT_TYPE_TYPEDBYREF` is `System.TypedReference`, a value type — not
    // an object reference — so its ABI spelling is its own decoded spelling.
    let type = SignatureType.primitive(.typedref)
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect)
                == type.decode(with: resolver, dialect: dialect))
  }

  @Test func `a class generic instantiation is a reference erased to a pointer`() {
    // A `GENERICINST` over a `CLASS` base names a runtime generic interface
    // (`IReference<Int>`, an object reference); it erases to the interface
    // pointer, not `IReference<CInt>`.
    let base = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      base.rawValue: Identity(namespace: "Windows.Foundation",
                              name: "IReference`1"),
    ])
    let type = SignatureType.instance(.named(kind: .class, base),
                                      [.primitive(.int4)])
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutableRawPointer")
    // The un-erased spelling — what the ABI replaces — is the generic.
    #expect(type.decode(with: resolver, dialect: dialect)
                == "IReference<CInt>")
  }

  @Test func `a value generic instantiation is a value keeping its spelling`() {
    // A `GENERICINST` over a `VALUETYPE` base is a generic struct, not an
    // object reference; it follows its base's kind and stays a value, so its
    // ABI keeps its own decoded generic spelling rather than erasing to the
    // opaque pointer.
    let base = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      base.rawValue: Identity(namespace: "Contoso", name: "Foo`1"),
    ])
    let type = SignatureType.instance(.named(kind: .value, base),
                                      [.primitive(.int4)])
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect)
                == type.decode(with: resolver, dialect: dialect))
    #expect(type.abi(with: resolver, dialect: dialect)
                == "Foo<CInt>")
  }

  @Test func `a pointer is a value decoding as its raw ABI form`() {
    // A pointer is already a raw ABI form, so it is a value and its ABI
    // spelling is its own decoded pointer spelling.
    let type = SignatureType.pointer(.primitive(.int4))
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<CInt>")
  }

  @Test func `a modifier is transparent to the ABI classification`() {
    // A modified type classifies (and erases) as its inner type: a modified
    // class reference is still a reference erased to the pointer.
    let foo = TypeDefOrRef(rawValue: 1)
    let marker = TypeDefOrRef(rawValue: 2)
    let resolver = Resolver([
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
      marker.rawValue: Identity(namespace: "System.Runtime.CompilerServices",
                                name: "IsConst"),
    ])
    let type = SignatureType.modified(.named(kind: .class, foo),
        modifiers: [Modifier(required: false, type: marker)])
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutableRawPointer")
  }

  @Test func `a byref class reference erases its element under the pointer`() {
    // An out-interface parameter is a BYREF class reference
    // (`reference(IFoo)`): the element is a reference, so the byref is a
    // reference too and its ABI spells a pointer over the ERASED element (the
    // opaque interface pointer), not over the concrete `IFoo`.
    let foo = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
    ])
    let type = SignatureType.reference(.named(kind: .class, foo))
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeMutableRawPointer>")
    // The un-erased spelling — what the ABI replaces — wraps the concrete type.
    #expect(type.decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<IFoo>")
  }

  @Test func `an interface array erases its element under the pointer`() {
    // An array of interfaces (`array(IFoo)`) is a reference (its element is),
    // so its ABI composes the array/pointer form over the ERASED element, not
    // over the concrete `IFoo`.
    let foo = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      foo.rawValue: Identity(namespace: "Contoso", name: "IFoo"),
    ])
    let type = SignatureType.array(.named(kind: .class, foo))
    #expect(type.classification == .reference)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<UnsafeMutableRawPointer>")
    #expect(type.decode(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<IFoo>")
  }

  @Test func `a pointer to a value is unchanged under erasure`() {
    // A value element under indirection stays a value, and its ABI spelling is
    // its own decoded pointer spelling — erasure touches only reference
    // elements.
    let type = SignatureType.pointer(.primitive(.int4))
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect)
                == type.decode(with: resolver, dialect: dialect))
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<CInt>")
  }

  @Test func `a byref value stays a value with its composed spelling`() {
    // A BYREF of a value type (a struct) is a value, and its ABI spelling is
    // the composed pointer over the value's own spelling — not the opaque
    // pointer.
    let point = TypeDefOrRef(rawValue: 1)
    let resolver = Resolver([
      point.rawValue: Identity(namespace: "Windows.Foundation", name: "Point"),
    ])
    let type = SignatureType.reference(.named(kind: .value, point))
    #expect(type.classification == .value)
    #expect(type.abi(with: resolver, dialect: dialect)
                == "UnsafeMutablePointer<Point>")
    #expect(type.abi(with: resolver, dialect: dialect)
                == type.decode(with: resolver, dialect: dialect))
  }
}
