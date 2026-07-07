// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQL
internal import WinMDSynthesis

/// A target-language spec — the language- and convention-specific knowledge the
/// render pipeline needs, kept OUT of the binary.
///
/// The generic engine and the render orchestration know only WinMD and SQL; what
/// makes the output *Swift* (its reserved words, how one escapes, the no-value
/// return spelling, the COM-root base, and the type spellings a signature decodes
/// to) is data, loaded from a bundled `Resources/Languages/<language>.lang`
/// resource — e.g. `swift.lang` — named for the language, which a template selects
/// through its `{{! language: <name> }}` directive and a user may shadow through
/// `-I`. Retargeting the generator to Rust or C is then a new spec beside a new
/// template, not a code change.
///
/// The spec surfaces to the render queries as the `SANITIZE` scalar UDF
/// (keyword-escape an identifier), and to the render's Swift decode as a
/// `Dialect` — the type spellings a `SignatureType` composes into a spelling. The
/// no-value return is the spec's `void` spelling, tested against a decoded return
/// (`returned(_:)`), so the render omits the return clause when the return is
/// absent.
///
/// The file is line-oriented: blank lines and `#`-comments are ignored; every
/// other line is `key value`, the value being the rest of the line after the
/// first whitespace (possibly empty). Recognised keys: `escape-prefix`/
/// `escape-suffix` (the delimiters wrapped around an escaped identifier), `void`
/// (the spelling a no-value return decodes to), `root` (the default base a COM
/// root inherits), `keyword` (one reserved word, repeated), `type <name>
/// <spelling>` (a primitive leaf's spelling, keyed by neutral name), the pointer
/// conventions (`pointer-mutable`/`pointer-const`/`rawpointer-mutable`/
/// `rawpointer-const`/`optional`/`generic-open`/`generic-close`/`var-type`/
/// `var-method`/`opaque`), the `System.Guid` names (`guid-iid`/`guid-clsid`), and
/// `wellknown <namespace.name> <spelling>`. An unknown key is ignored.
internal struct Language: Sendable {
  /// The delimiters wrapped around a keyword identifier — Swift's backticks, or
  /// (say) an empty prefix with a `_` suffix.
  private let prefix: String
  private let suffix: String

  /// The decoded spelling of a no-value return (`Void` in Swift); a method whose
  /// return equals it emits no return clause.
  private let void: String

  /// The base a COM root defaults to when it implements no interface (`IUnknown`
  /// in COM); an interface whose own name is `root` inherits nothing, so the COM
  /// root itself does not inherit itself.
  internal let root: String

  /// The reserved words `escape(_:)` wraps.
  private let keywords: Set<String>

  /// The primitive leaf spellings, keyed by neutral name (`void`, `i4`, …) — the
  /// `type` lines, fed to the `Dialect`.
  private let types: Dictionary<String, String>

  /// The type-composition conventions — the pointer family, delimiters, scope
  /// prefixes, the opaque spelling, and the `System.Guid` names — the `Dialect`
  /// composes a spelling from, keyed by their `.lang` key.
  private let conventions: Dictionary<String, String>

  /// The well-known projection of a `namespace.name` identity to its spelling —
  /// the `wellknown` lines, fed to the `Dialect`.
  private let wellKnown: Dictionary<String, String>

  /// The identity spec — no keywords, no `void`/`root` conventions, no type data
  /// — so a template with no accompanying `.lang` renders every identifier and
  /// return verbatim, applies no root default, and (through `dialect`) decodes a
  /// primitive to its neutral name.
  internal init() {
    prefix = ""
    suffix = ""
    void = ""
    root = ""
    keywords = []
    types = [:]
    conventions = [:]
    wellKnown = [:]
  }

  /// Parses a `.lang` resource, ignoring blank lines and `#`-comments and
  /// reading each remaining line as a `key value` pair.
  internal init(parsing text: String) {
    var prefix = "", suffix = "", void = "", root = ""
    var keywords = Set<String>()
    var types = Dictionary<String, String>()
    var conventions = Dictionary<String, String>()
    var wellKnown = Dictionary<String, String>()
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = String(line).trimmed
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      let key = trimmed.prefix { !$0.isWhitespace }
      let value = trimmed[key.endIndex...].trimmed
      switch key {
      case "escape-prefix": prefix = value
      case "escape-suffix": suffix = value
      case "void":          void = value
      case "root":          root = value
      case "keyword":       keywords.insert(value)
      case "type":
        // A `type <name> <spelling>` line: the neutral name then its spelling.
        let name = value.prefix { !$0.isWhitespace }
        types[String(name)] = value[name.endIndex...].trimmed
      case "wellknown":
        // A `wellknown <namespace.name> <spelling>` line.
        let identity = value.prefix { !$0.isWhitespace }
        wellKnown[String(identity)] = value[identity.endIndex...].trimmed
      case "pointer-mutable", "pointer-const", "rawpointer-mutable",
           "rawpointer-const", "optional", "generic-open", "generic-close",
           "var-type", "var-method", "opaque", "guid-iid", "guid-clsid":
        conventions[String(key)] = value
      default:              break
      }
    }
    self.prefix = prefix
    self.suffix = suffix
    self.void = void
    self.root = root
    self.keywords = keywords
    self.types = types
    self.conventions = conventions
    self.wellKnown = wellKnown
  }

  /// The target-source spelling of `identifier`: itself, or wrapped in the
  /// escape delimiters when it collides with a reserved keyword.
  internal func escape(_ identifier: String) -> String {
    keywords.contains(identifier) ? "\(prefix)\(identifier)\(suffix)" : identifier
  }

  /// The value-carrying return type a method spells, or `nil` for a no-value
  /// return — the `void` spelling, or an undecoded (empty) return. The render
  /// omits the return clause when it is absent.
  internal func returned(_ type: String) -> String? {
    type.isEmpty || type == void ? nil : type
  }

  /// The `WinMDSynthesis.Dialect` this spec builds — the type spellings and
  /// conventions the render's decode composes a signature's spelling from.
  ///
  /// A convention absent from the spec falls back to its neutral name (a `type`)
  /// or the empty string (a delimiter/prefix), so the identity `Language` still
  /// yields a usable, non-trapping dialect. The well-known table parses each
  /// `namespace.name` key into an `Identity` by splitting off the last `.`-
  /// segment as the simple name.
  internal var dialect: Dialect {
    var known = Dictionary<Identity, String>()
    for (identity, spelling) in wellKnown {
      guard let dot = identity.lastIndex(of: ".") else {
        known[Identity(namespace: "", name: identity)] = spelling
        continue
      }
      let namespace = String(identity[..<dot])
      let name = String(identity[identity.index(after: dot)...])
      known[Identity(namespace: namespace, name: name)] = spelling
    }
    let language = self
    return Dialect(
        primitives: types,
        pointer: (typed: (mutable: conventions["pointer-mutable"] ?? "",
                          constant: conventions["pointer-const"] ?? ""),
                  untyped: (mutable: conventions["rawpointer-mutable"] ?? "",
                            constant: conventions["rawpointer-const"] ?? "")),
        optional: conventions["optional"] ?? "",
        generic: (open: conventions["generic-open"] ?? "",
                  close: conventions["generic-close"] ?? ""),
        variable: (type: conventions["var-type"] ?? "",
                   method: conventions["var-method"] ?? ""),
        opaque: conventions["opaque"] ?? "",
        guid: (iid: conventions["guid-iid"] ?? "",
               clsid: conventions["guid-clsid"] ?? ""),
        known: known,
        escape: { language.escape($0) })
  }

  /// The spec's render UDFs — just `SANITIZE(identifier)` — for the routines the
  /// render binds its queries with. `SANITIZE` wraps a keyword identifier (and
  /// passes a NULL through); the no-value return is decided in Swift now (the
  /// render tests a decoded return against `returned(_:)`), so it needs no UDF.
  ///
  /// The UDF is spelled `SANITIZE`, not `ESCAPE`, to steer clear of the ISO-SQL
  /// reserved word `ESCAPE` (§8.5, the escape-character clause of a `LIKE`
  /// predicate) should `LIKE` ever be added to the engine.
  internal var routines: Routines {
    let language = self
    let sanitize:
        @Sendable (Array<Value>) throws(SQLError) -> Value = { arguments in
      guard arguments.count == 1 else {
        throw .argument("SANITIZE takes one argument")
      }
      if case .null = arguments[0] { return .null }
      guard case let .text(identifier) = arguments[0] else {
        throw .argument("SANITIZE requires a text argument")
      }
      return .text(language.escape(identifier))
    }
    // `SANITIZE` returns text over one text argument, so it declares both its
    // return type and its `[.text]` parameter contract — the signature the
    // static type-check validates a `SANITIZE(...)` call against. `try!`: the
    // name is a compile-time constant and not a protected standard routine, so
    // `registering` never faults it.
    return try! Routines().registering("sanitize", returns: .text,
                                       parameters: [.text], sanitize)
  }
}
