// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@testable import WinMD

/// A declarative facade over `WinMDFixture`: a fixture states the interfaces,
/// value types, and their members it needs and lets the builder assign the
/// `TypeDef` rids, thread the `FieldList`/`MethodList` links, encode the
/// signatures, and resolve every type reference to its coded-index token — the
/// bookkeeping a hand-built byte fixture otherwise spells by hand. It covers the
/// shapes the render tests exercise (interfaces with a GUID and methods, value
/// types with fields, nesting, external references, primitives); a shape it does
/// not model is still reachable through the row-level `WinMDFixture`.
///
/// A type is keyed by the string that declares it (`"R.IRoot"`, `"A.B.Point"`);
/// a reference names that same key. A top-level type's key is its
/// `namespace.name`; a nested type is declared with `nested:` and keyed
/// `encloser.name`.
final class WinMDBuilder {
  /// A type reference in a signature — a field's type, a method's parameter or
  /// return. A local reference names a declared type by its key; an external one
  /// names a type the fixture does not define (an `AssemblyRef`-scoped frontier);
  /// a primitive is an `ELEMENT_TYPE`; `void` is a method's absent return.
  indirect enum Ref {
    case value(String)          // a local value type (ELEMENT_TYPE_VALUETYPE)
    case object(String)         // a local class/interface (ELEMENT_TYPE_CLASS)
    case external(String)       // an external value type (a frontier)
    case reference(String)      // a local value type via a `TypeRef` chain
    case pointer(Ref)           // a pointer to `Ref` (ELEMENT_TYPE_PTR)
    case primitive(UInt8)       // an ELEMENT_TYPE code (e.g. 0x08 I4)
    case void
  }

  enum Kind { case interface, structure, enumeration, klass, delegate }

  /// A layout policy a value type declares — sequential is the default a value
  /// type projects; explicit or auto is the shape a layout-rejection test needs.
  enum Layout: UInt32 { case sequential = 0x08, explicit = 0x10, auto = 0x00 }

  final class Decl {
    let kind: Kind
    let namespace: String
    var name: String            // may carry the CLR arity backtick
    let encloser: String?       // the key of the enclosing type, if nested
    var guid: UInt32?
    var base: String?           // an interface base's key, for InterfaceImpl
    var external: String?       // an external interface base's name, via TypeRef
    var layout: Layout = .sequential
    var generics: Array<String> = []
    var fields: Array<(name: String, type: Ref, isStatic: Bool)> = []
    var methods: Array<(name: String, returns: Ref,
                        params: Array<(name: String, type: Ref)>)> = []
    var members: Array<(name: String, value: Int)> = []   // enum constants
    var underlying: Ref = .primitive(0x08)                // enum underlying (I4)

    init(_ kind: Kind, namespace: String, name: String, encloser: String?) {
      self.kind = kind
      self.namespace = namespace
      self.name = name
      self.encloser = encloser
    }

    @discardableResult
    func guid(_ seed: UInt32) -> Decl { self.guid = seed; return self }
    @discardableResult
    func refines(_ base: String) -> Decl { self.base = base; return self }
    @discardableResult
    func refines(external base: String) -> Decl {
      self.external = base; return self
    }
    @discardableResult
    func layout(_ layout: Layout) -> Decl { self.layout = layout; return self }
    @discardableResult
    func generic(_ names: String...) -> Decl {
      generics = names
      name = "\(name.prefix { $0 != "`" })`\(names.count)"
      return self
    }
    @discardableResult
    func field(_ name: String, _ type: Ref, static isStatic: Bool = false)
        -> Decl {
      fields.append((name, type, isStatic)); return self
    }
    @discardableResult
    func method(_ name: String, returns: Ref = .void,
                _ params: Array<(name: String, type: Ref)> = []) -> Decl {
      methods.append((name, returns, params)); return self
    }
    @discardableResult
    func member(_ name: String, _ value: Int) -> Decl {
      members.append((name, value)); return self
    }
    @discardableResult
    func underlying(_ type: Ref) -> Decl { self.underlying = type; return self }
  }

  private var types = Array<Decl>()
  private var keys = Dictionary<String, Decl>()

  private func split(_ declared: String) -> (String, String) {
    guard let dot = declared.lastIndex(of: ".") else { return ("", declared) }
    return (String(declared[..<dot]), String(declared[declared.index(after: dot)...]))
  }

  private func declare(_ kind: Kind, _ declared: String,
                       nested encloser: String?) -> Decl {
    let (namespace, name) =
        encloser == nil ? split(declared) : ("", declared)
    let type = Decl(kind, namespace: namespace, name: name, encloser: encloser)
    types.append(type)
    keys[encloser.map { "\($0).\(declared)" } ?? declared] = type
    return type
  }

  @discardableResult
  func interface(_ declared: String, guid: UInt32? = nil,
                 nested encloser: String? = nil) -> Decl {
    let type = declare(.interface, declared, nested: encloser)
    type.guid = guid
    return type
  }

  @discardableResult
  func structure(_ declared: String, nested encloser: String? = nil) -> Decl {
    declare(.structure, declared, nested: encloser)
  }

  @discardableResult
  func enumeration(_ declared: String, nested encloser: String? = nil) -> Decl {
    declare(.enumeration, declared, nested: encloser)
  }

  @discardableResult
  func klass(_ declared: String, nested encloser: String? = nil) -> Decl {
    declare(.klass, declared, nested: encloser)
  }

  @discardableResult
  func delegate(_ declared: String, guid: UInt32? = nil) -> Decl {
    let type = declare(.delegate, declared, nested: nil)
    type.guid = guid
    return type
  }

  /// Assembles the declared model into a `WinMDFixture` — assigning rids,
  /// linking member lists, encoding signatures, and resolving references.
  func assemble() -> WinMDFixture {
    let f = WinMDFixture()
    let metadata = f.string("Windows.Win32.Foundation.Metadata")
    let guidAttr = f.string("GuidAttribute")
    let system = f.string("System")
    f.row(1, Coded.u16(0) + Coded.u16(guidAttr) + Coded.u16(metadata))  // rid1

    // The `extends` TypeRefs a value type needs (`System.ValueType`/`.Enum`),
    // fabricated once and shared, and each distinct external reference.
    var refs = Dictionary<String, Int>()
    func reference(_ namespace: Int, _ name: Int, scope: Int) -> Int {
      f.row(1, Coded.u16(scope) + Coded.u16(name) + Coded.u16(namespace))
    }
    func extends(_ name: String) -> Int {
      if let rid = refs[name] { return Coded.index(1, rid) }
      let rid = reference(system, f.string(name), scope: 0)
      refs[name] = rid
      return Coded.index(1, rid)
    }
    // A distinct external reference (AssemblyRef-scoped), one AssemblyRef shared.
    var externals = Dictionary<String, Int>()
    var assembly = 0
    func external(_ name: String) -> Int {
      if let rid = externals[name] { return rid }
      if assembly == 0 { assembly = f.row(0x23, Array(repeating: 0, count: 20)) }
      let rid = reference(0, f.string(name), scope: Coded.index(2, assembly))
      externals[name] = rid
      return rid
    }

    // Assign each declared type its 1-based TypeDef rid up front, so a forward
    // reference (a method returning a type declared later) resolves.
    var rids = Dictionary<ObjectIdentifier, Int>()
    for (index, type) in types.enumerated() {
      rids[ObjectIdentifier(type)] = index + 1
    }
    // The Module-scoped `TypeRef` chain that resolves a local type by name — a
    // top-level reference anchored at the `Module`, each nested one to its
    // encloser's. Naming a leaf through this chain (not the direct `TypeDef`
    // `.value`/`.object` tokens) exercises the `TypeRef` resolution the walk
    // performs, so a nested value type is classified off its resolved
    // definition, not the reference row.
    var chains = Dictionary<ObjectIdentifier, Int>()
    func chain(_ decl: Decl) -> Int {
      if let rid = chains[ObjectIdentifier(decl)] { return rid }
      let scope = decl.encloser.map { Coded.index(3, chain(keys[$0]!)) }
          ?? Coded.index(0, 1)
      let rid = reference(f.string(decl.namespace), f.string(decl.name),
                          scope: scope)
      chains[ObjectIdentifier(decl)] = rid
      return rid
    }
    func token(_ ref: Ref) -> Array<UInt8> {
      switch ref {
      case let .value(key):
        [0x11, UInt8(Coded.index(0, rids[ObjectIdentifier(keys[key]!)]!))]
      case let .object(key):
        [0x12, UInt8(Coded.index(0, rids[ObjectIdentifier(keys[key]!)]!))]
      case let .external(name):
        [0x11, UInt8(Coded.index(1, external(name)))]
      case let .reference(key):
        [0x11, UInt8(Coded.index(1, chain(keys[key]!)))]
      case let .pointer(inner):
        [0x0f] + token(inner)
      case let .primitive(code):
        [code]
      case .void:
        [0x01]
      }
    }

    // Emit the TypeDef rows with their FieldList/MethodList links, then the
    // FieldDef/MethodDef/Param rows in the same order the links index into.
    var fieldList = 1, methodList = 1
    struct Pending { let type: Decl; let field: Int; let method: Int }
    var pending = Array<Pending>()
    for type in types {
      let flags: UInt32
      let base: Int
      switch type.kind {
      case .interface: (flags, base) = (0x21, 0)
      case .structure: (flags, base) = (type.layout.rawValue,
                                        extends("ValueType"))
      case .enumeration: (flags, base) = (0x08, extends("Enum"))
      case .klass: (flags, base) = (0, extends("Object"))
      case .delegate: (flags, base) = (0, extends("MulticastDelegate"))
      }
      pending.append(Pending(type: type, field: fieldList, method: methodList))
      f.row(2, Coded.u32(Int(flags)) + Coded.u16(f.string(type.name))
              + Coded.u16(f.string(type.namespace)) + Coded.u16(base)
              + Coded.u16(fieldList) + Coded.u16(methodList))
      fieldList += type.fields.count
      methodList += type.methods.count
    }
    for entry in pending {
      for field in entry.type.fields {
        // A static field carries `fdStatic` (0x10), excluded from a struct's
        // instance layout; an instance field is 0.
        let flags = field.isStatic ? 0x10 : 0
        let sig = f.blob([0x06] + token(field.type))
        f.row(4, Coded.u16(flags) + Coded.u16(f.string(field.name))
                + Coded.u16(sig))
      }
    }
    // MethodDef rows and their Param rows. A parameter is `Sequence`-numbered
    // from 1; the render reads a parameter's type from its owning signature.
    var paramList = 1
    struct Method { let name: Int; let sig: Int; let params: Int }
    var records = Array<Method>()
    for type in types {
      for method in type.methods {
        var sig: Array<UInt8> = [0x20, UInt8(method.params.count)]
        sig += token(method.returns)
        for param in method.params { sig += token(param.type) }
        records.append(Method(name: f.string(method.name),
                              sig: f.blob(sig), params: paramList))
        paramList += method.params.count
      }
    }
    for (index, type) in types.enumerated() {
      _ = index
      for method in type.methods {
        let record = records.removeFirst()
        f.row(6, Coded.u32(0) + Coded.u16(0) + Coded.u16(0x05C6)
                + Coded.u16(record.name) + Coded.u16(record.sig)
                + Coded.u16(record.params))
        var sequence = 1
        for param in method.params {
          f.row(8, Coded.u16(0) + Coded.u16(sequence)
                  + Coded.u16(f.string(param.name)))
          sequence += 1
        }
      }
    }

    // The GuidAttribute ctor, referenced by every `@com` type's attribute.
    let ctor = f.string(".ctor")
    let ctorSig = f.blob([0x20, 0x02, 0x01, 0x08, 0x0f])
    let member = f.row(10, Coded.u16(Coded.index(1, 1, bits: 3))
                          + Coded.u16(ctor) + Coded.u16(ctorSig))
    // CustomAttribute rows sorted by their `Parent` coded index (a seekable
    // table), so a type's GUID resolves.
    var attributes = Array<(parent: Int, value: Int)>()
    for type in types {
      guard let seed = type.guid else { continue }
      let value = f.blob([0x01, 0x00] + Coded.u32(Int(seed))
                         + [0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34,
                            0x56, 0x78, 0x90, 0xab, 0x00, 0x00])
      let parent = Coded.index(3, rids[ObjectIdentifier(type)]!, bits: 5)
      attributes.append((parent, value))
    }
    for attribute in attributes.sorted(by: { $0.parent < $1.parent }) {
      f.row(12, Coded.u16(attribute.parent)
              + Coded.u16(Coded.index(3, member, bits: 3))
              + Coded.u16(attribute.value))
    }

    // InterfaceImpl rows: an interface refines its declared base directly.
    for type in types {
      guard let base = type.base, let target = keys[base] else { continue }
      f.row(9, Coded.u16(rids[ObjectIdentifier(type)]!)
              + Coded.u16(Coded.index(0, rids[ObjectIdentifier(target)]!)))
    }
    // An interface refining an *external* base names it through a TypeRef, so
    // the closure's local-only requires walk sees no base while the `bases` view
    // still resolves the name — the external-base frontier scenario.
    for type in types {
      guard let base = type.external else { continue }
      f.row(9, Coded.u16(rids[ObjectIdentifier(type)]!)
              + Coded.u16(Coded.index(1, external(base))))
    }
    // NestedClass rows: a nested type under its encloser.
    for type in types {
      guard let encloser = type.encloser, let outer = keys[encloser]
      else { continue }
      f.row(0x29, Coded.u16(rids[ObjectIdentifier(type)]!)
                 + Coded.u16(rids[ObjectIdentifier(outer)]!))
    }
    // GenericParam rows: a generic type's parameters, owned by its TypeDef
    // (`TypeOrMethodDef` tag 0), numbered from 0. Their presence — not their
    // names — is what tells a generic interface/delegate apart in the render.
    for type in types where !type.generics.isEmpty {
      let owner = Coded.index(0, rids[ObjectIdentifier(type)]!, bits: 1)
      for (number, name) in type.generics.enumerated() {
        f.row(0x2A, Coded.u16(number) + Coded.u16(0) + Coded.u16(owner)
                   + Coded.u16(f.string(name)))
      }
    }
    return f
  }

  func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    try assemble().with(body)
  }
}
