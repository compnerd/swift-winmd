// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The engine's adapter surface — the protocols a data source conforms to so
/// the planner and executor run over it without knowing what it is.
///
/// The engine plans and executes a `SELECT` entirely against these four
/// protocols. A `Catalog` resolves a relation name to a `Table`; a `Table`
/// describes the relation's schema (its real width and a name → ordinal map,
/// real or virtual) and vends a `Cursor` over its rows; a `Cursor` addresses
/// rows by index; a `Row` reads a typed cell by ordinal. Every protocol is
/// `~Escapable`, so a source backed by borrowed storage — a `Span` over a
/// mapped file — conforms to the same surface as an escapable, owned source: a
/// `Catalog`/`Table` hands back a borrowed `Table`/`Cursor` that never outlives
/// the borrow, and a `Cursor` vends a `Row` view tied to its own lifetime. The
/// engine yields typed `Value`s, never rendered text; turning a value into a
/// display string is a client's job.

// MARK: - Values

/// The type of value a column holds.
///
/// A column is integral, approximate-numeric, textual, truth-valued, or binary.
/// A source uses this to describe its schema and to build the typed `Value`s a
/// `Row` yields; the engine itself compares and orders on the `Value`, not the
/// type.
public enum ValueType: Hashable, Sendable {
  /// An integral column — exact numeric.
  case integer
  /// An approximate-numeric column — SQL `FLOAT`/`REAL`/`DOUBLE PRECISION`,
  /// carried as a binary64 `Double`.
  case double
  /// A textual column.
  case text
  /// A truth-valued column — `TRUE` or `FALSE`; its UNKNOWN is `NULL`.
  case boolean
  /// A binary column — an uninterpreted byte string.
  case blob

  /// Whether the type is numeric — an `integer` or a `double`. Arithmetic and
  /// the folding aggregates (`SUM`/`AVG`) require a numeric operand; text,
  /// boolean, and blob have no arithmetic (`Arithmetic.apply`/`Aggregate.fold`
  /// fault `SQLError.operand` on them).
  internal var numeric: Bool {
    switch self {
    case .integer, .double: true
    case .text, .boolean, .blob: false
    }
  }

  /// The single type a value of this type and one of `other` UNIFY to, or `nil`
  /// when they are irreconcilable — the rule a `CASE` reconciles its result
  /// types by. Like types unify to themselves; a mixed integer/double pair
  /// widens to `double` (both numeric, the integer promoted, as arithmetic and
  /// comparison do); any other cross-kind pair — text against a number, boolean
  /// against blob — has no common type and does not unify.
  internal func unified(with other: ValueType) -> ValueType? {
    if self == other { return self }
    if numeric && other.numeric { return .double }
    return nil
  }

  /// Whether a value of this type can convert to `target` under `CAST` for AT
  /// LEAST ONE value — the STRUCTURAL half of `Value.cast(to:)`, the one shared
  /// truth both the runtime cast and the schema type-check consult so they
  /// cannot drift.
  ///
  /// A pair is castable when `Value.cast(to:)` has a conversion arm for it; an
  /// UNSUPPORTED pair — the one that falls to `Value.cast`'s `42846` arm for
  /// EVERY value of this kind — is not. A like-kind cast is the identity; a
  /// numeric pair converts (`integer` ↔ `double`); `text` bridges every kind
  /// (each type spells to and parses from text) and `blob` bridges `text`
  /// alone. The remaining cross-kind pairs — a boolean against a number or a
  /// blob, a number against a blob — have no ISO conversion.
  ///
  /// A castable pair may still fault at RUN time on a particular value — a
  /// `text` that is not a number, a `double` past `Int` range, a `blob` that is
  /// not UTF-8 — so a reachable good value runs; only a NEVER-castable pair is
  /// an unconditional fault the schema rejects early.
  internal func castable(to target: ValueType) -> Bool {
    switch (self, target) {
    case (.integer, .integer), (.double, .double), (.text, .text),
         (.boolean, .boolean), (.blob, .blob):
      true
    case (.integer, .double), (.double, .integer):
      true
    case (.text, _), (_, .text):
      true
    default:
      false
    }
  }

  /// The ISO `data_type` spelling of this value type.
  ///
  /// The engine's types map onto the ISO domains: exact numeric to `integer`,
  /// approximate numeric to `double precision`, character to `character
  /// varying`, truth-valued to `boolean`, and binary to `binary varying`.
  public var domain: String {
    switch self {
    case .integer: "integer"
    case .double: "double precision"
    case .text: "character varying"
    case .boolean: "boolean"
    case .blob: "binary varying"
    }
  }
}

/// A typed cell value the engine yields.
///
/// The engine projects each surviving row to an `Array<Value>` — the result is
/// data, not rendered text — so a client may format, compare, or re-key it. A
/// cell may also be `null` — SQL's absent value, distinct from any integer or
/// text, unordered and unequal to everything (itself included) — which a source
/// yields for a column that has no value in a row (a decoded attribute that does
/// not apply), and which a comparison evaluates under three-valued logic.
public enum Value: Hashable, Sendable {
  /// SQL `NULL` — the absence of a value.
  case null
  /// An integral value — exact numeric.
  case integer(Int)
  /// An approximate-numeric value — SQL `FLOAT`/`REAL`/`DOUBLE PRECISION`,
  /// carried as a binary64 `Double`. A double compares and does arithmetic with
  /// another double, and — both being numeric — with an `integer` too, the
  /// integer promoted to `Double`; a mixed integer/double arithmetic yields a
  /// double, and `/` is real division (no truncation).
  ///
  /// INVARIANT: a `double` must be FINITE — never `inf` or NaN. NaN is unequal
  /// to itself, so it would break UNION/CTE duplicate elimination and ordering;
  /// the engine's producers enforce this (a literal or arithmetic result past
  /// range faults, a routine's non-finite result is rejected), so a `Catalog`,
  /// `Row`, and `Scalar` must likewise vend only finite doubles.
  case double(Double)
  /// A textual value.
  case text(String)
  /// A truth value — `TRUE` or `FALSE`. Its UNKNOWN is the existing `null`; a
  /// boolean cell is never a fourth truth value, and orders `false < true`.
  case boolean(Bool)
  /// A binary value — an uninterpreted byte string. Two blobs compare by byte
  /// equality (`=`/`<>`) and lexicographic order (`<`/`>`/`<=`/`>=`), both free
  /// from `Array<UInt8>: Comparable`.
  case blob(Array<UInt8>)
}

extension Value {
  /// This value coerced to `type` — the widening a `CASE` (or a defined
  /// function body) applies so a selected branch's raw value matches the
  /// unified result type the schema advertises.
  ///
  /// `ValueType.unified` performs one widening only — a mixed integer/double
  /// pair to `.double` — so this promotes an `.integer` to `.double` when
  /// `type` is `.double` and leaves every other value unchanged: NULL stays
  /// NULL, a value already of the unified type passes through, and a
  /// non-widening unified type (every arm the same) needs no coercion.
  internal func coerced(to type: ValueType) -> Value {
    if case .double = type, case let .integer(number) = self {
      return .double(Double(number))
    }
    return self
  }

  /// This value CONVERTED to `type` — the ISO `CAST(… AS type)` explicit
  /// conversion, wider than the numeric-widening `coerced(to:)`.
  ///
  /// `NULL` converts to `NULL` for every target. A value already of `type`
  /// passes through. The remaining conversions form the supported matrix:
  ///
  /// - `integer` ↔ `double`: an integer widens to a double exactly; a double
  ///   TRUNCATES toward zero to an integer (`1.9` → `1`, `-1.9` → `-1`), the
  ///   ISO exact-numeric-from-approximate rule, faulting when the truncated
  ///   magnitude exceeds `Int` (`22003`).
  /// - number → `text`: its canonical spelling (`42`, `1.5`).
  /// - `text` → `integer`/`double`: the parsed number, its surrounding
  ///   whitespace trimmed; an unparseable spelling faults `22018` (invalid
  ///   character value for cast). A `double` that parses to a non-finite
  ///   magnitude (`1e999`) is out of range (`22003`).
  /// - `boolean` → `text`: `true`/`false`; `text` → `boolean`: the ISO
  ///   truth-value spellings `true`/`false`/`t`/`f`/`yes`/`no`/`on`/`off`/`1`/
  ///   `0` (case-insensitively, trimmed), else `22018`.
  /// - `text` ↔ `blob`: the text's UTF-8 octets, and a blob decoded as UTF-8
  ///   text (invalid UTF-8 faults `22018`).
  ///
  /// Every other cross-kind pair — a number against a boolean or a blob, a
  /// boolean against a blob — has no ISO conversion and faults `SQLError.state`
  /// `42846` (cannot coerce). These are exactly the pairs
  /// `ValueType.castable(to:)` rejects: its conversion arms below cover the
  /// castable pairs, and this `default` arm faults for the rest, so the
  /// structural predicate the schema type-check consults cannot drift from the
  /// runtime cast.
  internal func cast(to type: ValueType) throws(SQLError) -> Value {
    switch (self, type) {
    case (.null, _):
      return .null

    // A value already of the target type is unchanged.
    case (.integer, .integer), (.double, .double), (.text, .text),
         (.boolean, .boolean), (.blob, .blob):
      return self

    // integer ↔ double: exact widening, truncating narrowing.
    case let (.integer(number), .double):
      return .double(Double(number))
    case let (.double(number), .integer):
      let truncated = number.rounded(.towardZero)
      guard truncated >= Double(Int.min), truncated < -Double(Int.min) else {
        throw .magnitude("double '\(number)' out of Int range for cast")
      }
      return .integer(Int(truncated))

    // number → text: canonical spelling.
    case let (.integer(number), .text):
      return .text("\(number)")
    case let (.double(number), .text):
      return .text("\(number)")

    // text → number: parse the trimmed spelling.
    case let (.text(text), .integer):
      // gate the trimmed spelling against the SQL INTEGER format FIRST (mirror
      // the text → double `decimal` split): a malformed spelling ('12abc',
      // '1.5') is an invalid character (`22018`), while a format-valid spelling
      // `Int(_:)` still cannot represent ('9223372036854775808') is a numeric
      // value out of range (`22003`), the same fault an integer-literal
      // overflow and the double → integer range check use.
      let spelling = text.trimmed
      guard spelling.integer else {
        throw .state("22018", "cannot cast '\(text)' to integer")
      }
      guard let number = Int(spelling) else {
        throw .magnitude("integer '\(text)' out of range for cast")
      }
      return .integer(number)
    case let (.text(text), .double):
      // `Double(_:)` accepts Swift spellings the SQL numeric grammar does not —
      // a hex float `0x1p2`, `inf`/`infinity`/`nan`, an underscore group — so
      // gate the trimmed spelling against the SQL DECIMAL format FIRST: only a
      // format-valid spelling reaches `Double(_:)`, and the `isFinite` guard
      // then catches a valid-format magnitude past range (`1e999` → `22003`).
      let spelling = text.trimmed
      guard spelling.decimal, let number = Double(spelling) else {
        throw .state("22018", "cannot cast '\(text)' to double")
      }
      guard number.isFinite else {
        throw .magnitude("double '\(text)' out of range for cast")
      }
      return .double(number)

    // boolean ↔ text.
    case let (.boolean(truth), .text):
      return .text(truth ? "true" : "false")
    case let (.text(text), .boolean):
      return switch text.trimmed.lowercased() {
      case "true", "t", "yes", "on", "1": .boolean(true)
      case "false", "f", "no", "off", "0": .boolean(false)
      default: throw .state("22018", "cannot cast '\(text)' to boolean")
      }

    // text ↔ blob: the UTF-8 octets, and their decode.
    case let (.text(text), .blob):
      return .blob(Array(text.utf8))
    case let (.blob(bytes), .text):
      var decoder = UTF8()
      var iterator = bytes.makeIterator()
      var text = ""
      loop: while true {
        switch decoder.decode(&iterator) {
        case let .scalarValue(scalar): text.unicodeScalars.append(scalar)
        case .emptyInput: break loop
        case .error: throw .state("22018", "cannot cast blob to text")
        }
      }
      return .text(text)

    default:
      throw .state("42846",
                   "cannot cast \(self.type.domain) to \(type.domain)")
    }
  }

  /// The `ValueType` of this value's kind — a `null` has no kind of its own, so
  /// it reports `.integer`, the schema default; it is used only to describe an
  /// unconvertible cast, and a `null` never reaches that arm (it casts to
  /// `null` for every target).
  private var type: ValueType {
    switch self {
    case .null, .integer: .integer
    case .double: .double
    case .text: .text
    case .boolean: .boolean
    case .blob: .blob
    }
  }
}

extension String {
  /// This string with leading and trailing ASCII whitespace removed — the
  /// surrounding space an ISO `CAST` of a character string to a number ignores.
  fileprivate var trimmed: String {
    let space: Set<Character> = [" ", "\t", "\n", "\r"]
    return String(drop { space.contains($0) }.reversed()
                      .drop { space.contains($0) }.reversed())
  }

  /// Whether this string is a SQL DECIMAL numeric spelling — an optional
  /// leading sign, a digit run, an optional `.` fraction, and an optional
  /// `e`/`E` exponent (its own optional sign then a digit run) — the same
  /// grammar the lexer scans a numeric literal by. It admits NO Swift extension
  /// `Double(_:)` accepts: no hexadecimal (`0x`, a `p` exponent), no
  /// `inf`/`infinity`/`nan`, no underscore digit groups. A CAST of a character
  /// string to a number validates its spelling against this before parsing, so
  /// a format the engine would not lex is an invalid character (`22018`), never
  /// a Swift value.
  fileprivate var decimal: Bool {
    var characters = Substring(self)
    func digits() -> Bool {
      let count = characters.count
      characters = characters.drop { $0.isASCIIDigit }
      return characters.count < count
    }
    if characters.first == "+" || characters.first == "-" {
      characters = characters.dropFirst()
    }
    guard digits() else { return false }
    if characters.first == "." {
      characters = characters.dropFirst()
      guard digits() else { return false }
    }
    if characters.first == "e" || characters.first == "E" {
      characters = characters.dropFirst()
      if characters.first == "+" || characters.first == "-" {
        characters = characters.dropFirst()
      }
      guard digits() else { return false }
    }
    return characters.isEmpty
  }

  /// Whether this string is a SQL INTEGER numeric spelling — an optional
  /// leading sign then a digit run, with NO fraction, exponent, hexadecimal,
  /// underscore group, or `inf`/`nan`. A CAST of a character string to an
  /// integer validates its spelling against this before parsing, so a malformed
  /// spelling is an invalid character (`22018`) while a format-valid spelling
  /// `Int(_:)` cannot represent is a numeric value out of range (`22003`), not
  /// a Swift `nil` conflated with the malformed case.
  fileprivate var integer: Bool {
    var characters = Substring(self)
    if characters.first == "+" || characters.first == "-" {
      characters = characters.dropFirst()
    }
    let count = characters.count
    characters = characters.drop { $0.isASCIIDigit }
    return characters.count < count && characters.isEmpty
  }
}

extension Character {
  /// Whether this character is an ASCII decimal digit, `0`–`9` — the digit the
  /// SQL numeric grammar admits, excluding the Unicode digits the broader
  /// `Character.isNumber` would.
  fileprivate var isASCIIDigit: Bool {
    return isASCII && isNumber
  }
}

// MARK: - View

/// A named query registered as a first-class relation.
///
/// A view is a stored query the engine resolves wherever a base table is: its
/// `query` is the `SELECT` — or `UNION` of several — that produces the rows,
/// and `columns` names the relation's columns in projection order — column `i`
/// is the `i`th projected value of the query's first arm. A view is fully
/// escapable data — no borrowed storage — so it sits beside the `~Escapable`
/// base tables in the same catalog namespace; a catalog vends one through
/// `view(named:)`. The engine compiles a view's `query` into a sub-plan and
/// splices it in where the view is named, the outer query addressing the view's
/// columns by their ordinal in `columns`. A view carries no virtual column, so
/// its `extent` is its `columns` count.
public struct View: Hashable, Sendable {
  /// The query the view stands for.
  public let query: Query

  /// The view's column names, in projection order — column `i` is the `i`th
  /// projected value of the query's first arm.
  public let columns: Array<String>

  public init(query: Query, columns: Array<String>) {
    self.query = query
    self.columns = columns
  }
}

// MARK: - Catalog

/// Resolves a relation name to a table or a view.
///
/// The catalog is the engine's only entry into a data source: a `SELECT`'s
/// `FROM` name is looked up here. A name the source does not know as either a
/// table or a view yields `nil` from both, which the engine reports as
/// `SQLError.relation`. The catalog is `~Escapable`, and the `Table` it vends
/// borrows it — a borrowed-storage source may resolve a relation to a view that
/// never escapes the catalog's borrow. A view, by contrast, is escapable data:
/// a catalog that registers none returns `nil` from the default `view(named:)`.
public protocol Catalog: ~Escapable {
  /// The table this catalog vends.
  associatedtype Table: SQL.Table & ~Escapable

  /// The table named `name`, or `nil` if the source has no such base relation.
  @_lifetime(borrow self)
  borrowing func table(named name: String) -> Table?

  /// The view named `name`, or `nil` if the source registers no such view.
  ///
  /// The engine resolves a `FROM`/`JOIN` name against the views first: a name a
  /// catalog registers as a view shadows a base table of the same name. The
  /// default registers no view, so a source without stored queries need not
  /// implement it.
  borrowing func view(named name: String) -> View?

  /// The names of every base relation the catalog holds, in any order.
  ///
  /// Where `table(named:)` resolves ONE name, this enumerates them all — the
  /// surface the engine's `INFORMATION_SCHEMA` overlay walks to build its
  /// `tables`/`columns` metadata. An `Array<String>` is escapable owned data,
  /// so the enumeration stays `~Escapable`-safe over a borrowed source. Every
  /// catalog implements it; a source that cannot enumerate its relations
  /// returns `[]` (its metadata is then empty rather than wrong).
  borrowing func relations() -> Array<String>

  /// The names of every view the catalog registers, in any order.
  ///
  /// The `INFORMATION_SCHEMA` overlay lists these with a `'VIEW'` table type
  /// beside the base `relations()`. The default is empty — a source with no
  /// stored queries need not implement it, matching `view(named:)`.
  borrowing func views() -> Array<String>
}

extension Catalog where Self: ~Escapable {
  /// A catalog with no stored queries registers no view.
  public borrowing func view(named name: String) -> View? { nil }

  /// A catalog with no stored queries lists no view.
  public borrowing func views() -> Array<String> { [] }
}

// MARK: - Table

/// A relation's schema and its cursor factory.
///
/// A `Table` knows its real column count (`width`, the extent of `SELECT *`),
/// its `extent` (one past the highest ordinal it can address, real or virtual),
/// resolves a column name to an ordinal (a real ordinal `< width`, or a virtual
/// ordinal `>= width` for a computed column such as an `Id`), and — for a
/// column whose rows are stored in sorted order — maps a comparison value to a
/// row boundary so the executor can seek rather than scan. `cursor()` borrows
/// the table and hands back a cursor tied to that borrow.
public protocol Table: ~Escapable {
  /// The cursor this table vends over its rows.
  associatedtype Cursor: SQL.Cursor & ~Escapable

  /// The number of real columns — the extent of a `SELECT *` projection.
  var width: Int { get }

  /// The real column names, in ordinal order — column `i` of `names` is the
  /// name of the real column at ordinal `i`.
  ///
  /// A relation knows its own column names; the engine reads them to lift a
  /// base table's resolution onto an escapable `Schema` so a join may resolve a
  /// view against a base table uniformly. The virtual columns (`Id`, an owner
  /// foreign key) are not in `names`; they resolve through `ordinal(of:)`.
  var names: Array<String> { get }

  /// The value type of each real column, in ordinal order — type `i` is the
  /// type of the real column at ordinal `i`, so `types.count == width`.
  ///
  /// The engine reads these only to describe a relation's schema — the
  /// `INFORMATION_SCHEMA` overlay's `data_type` column and
  /// `Engine.outputSchema` — never to compare or order (that runs on the
  /// `Value` a `Row` yields). The default is `.integer` for every column, so a
  /// source that does not type its schema advertises an all-integral relation;
  /// a source that knows its column types overrides it. The virtual columns
  /// (`Id`, an owner foreign key) are not typed here — not being ISO columns.
  var types: Array<ValueType> { get }

  /// The virtual column names, in ordinal order — virtual `i` of `virtuals`
  /// sits at ordinal `width + i`.
  ///
  /// A virtual column is computed by the `Row` rather than stored (an `Id`, an
  /// owner foreign key); naming them lets the engine lift resolution onto an
  /// escapable `Schema`. The default is empty — a relation overrides it only
  /// when it computes a virtual column, and then its `extent` is `width +
  /// virtuals.count`.
  var virtuals: Array<String> { get }

  /// One past the highest ordinal this table can address — its real `width`
  /// plus the virtual columns it exposes.
  ///
  /// A relation with no virtual column has `extent == width`; one exposing an
  /// `Id` at `width` has `extent == width + 1`, and so on. A join lays the
  /// inner relation immediately past the outer's `extent` so an outer virtual
  /// column never collides with the inner's space. The default is `width` — a
  /// relation overrides it only when it computes a virtual column.
  var extent: Int { get }

  /// The ordinal of the column named `name`, or `nil` if the relation has no
  /// such column.
  ///
  /// A real column resolves to an ordinal `< width`; a virtual column — one the
  /// `Row` computes rather than stores, such as an `Id` — resolves to an
  /// ordinal `>= width`.
  func ordinal(of name: String) -> Int?

  /// The boundary row for a sorted-seek over `column` against `value`, or `nil`
  /// if the column is not seekable (the engine then scans).
  ///
  /// When the rows are sorted on `column`, this returns the partition point for
  /// `value`: with `strict` false, the first row whose cell is `>= value`; with
  /// `strict` true, the first row whose cell is `> value`. A column that is not
  /// stored sorted returns `nil`, and the executor falls back to a scan.
  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int?

  /// Whether `column`'s cells are monotonically non-decreasing in row order, so
  /// a `bound` partition brackets a range as well as an equality.
  ///
  /// A `bound` boundary is a valid range partition only when the column the
  /// engine reads is itself sorted — a `<`/`<=`/`>`/`>=` filter takes the rows
  /// on one side of the boundary, which is correct only if every row on that
  /// side compares that way. A column whose `bound` seeks a physically-sorted
  /// *encoding* whose decoded cell is not ordered like the stored one — a
  /// decoded coded-index key, whose raw run brackets one tag's equal value
  /// while the other tags interleaved by row decode to `NULL` — reports
  /// `false`, so the engine seeks only its equality and scans a range. The
  /// default is `true` — a relation overrides it only for an unordered column.
  func ordered(_ column: Int) -> Bool

  /// A cursor over the table's rows.
  @_lifetime(borrow self)
  borrowing func cursor() -> Cursor
}

extension Table where Self: ~Escapable {
  /// A relation with no virtual column ends at its real `width`.
  public var extent: Int { width }

  /// A relation that does not type its schema advertises every real column as
  /// integral, so `types.count` still equals `width`.
  public var types: Array<ValueType> {
    Array(repeating: .integer, count: width)
  }

  /// A relation exposes no virtual column by default.
  public var virtuals: Array<String> { [] }

  /// A seekable column is ordered by default — its `bound` boundary brackets a
  /// range as well as an equality.
  public func ordered(_ column: Int) -> Bool { true }
}

// MARK: - Cursor

/// An index-addressed view over a relation's rows.
///
/// A `~Escapable` view cannot conform to `Sequence`/`IteratorProtocol`, so the
/// executor walks it by index — `0 ..< count`, reading `row(i)`. A row borrows
/// the cursor and never escapes that borrow.
public protocol Cursor: ~Escapable {
  /// The row this cursor vends.
  associatedtype Row: SQL.Row & ~Escapable

  /// The number of rows the cursor walks.
  var count: Int { get }

  /// The row at `index`, or `nil` if `index` is out of range.
  @_lifetime(copy self)
  borrowing func row(_ index: Int) -> Row?
}

// MARK: - Row

/// A positional view over the cells of a single row.
///
/// A cell is read by ordinal as a typed `Value` — the source decides whether the
/// ordinal names an integral or a textual cell, and a virtual ordinal (one
/// `>= Table.width`) is computed here rather than stored. The row borrows its
/// cursor and never escapes that borrow; the `Value` it yields is owned and
/// escapable.
public protocol Row: ~Escapable {
  /// The typed cell of column `column`.
  subscript(_ column: Int) -> Value { borrowing get }
}
