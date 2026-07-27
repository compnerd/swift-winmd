// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising the `LIKE` predicate: a text `Name` that is `NULL` in
/// one row (so the three-valued NULL-operand corner is reachable), an integer
/// `K` for the cross-kind (non-text) operand case, and an `Id` to project.
private func names() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "Name": .text, "K": .integer]) {
      Row(1, "abc", 10)
      Row(2, "abd", 20)
      Row(3, "xyz", 30)
      Row(4, nil, 40)
    }
  }
}

// MARK: - Parsing

struct LikeParsingTests {
  @Test func `parses a LIKE pattern`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Name LIKE 'a%'")
    #expect(select.predicate
                == .like(.column("Name"),
                         pattern: .expression(.literal(.string("a%"))),
                         escape: nil, negated: false))
  }

  @Test func `parses a NOT LIKE pattern`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Name NOT LIKE 'a%'")
    #expect(select.predicate
                == .like(.column("Name"),
                         pattern: .expression(.literal(.string("a%"))),
                         escape: nil, negated: true))
  }

  @Test func `parses a LIKE with an ESCAPE character`() throws {
    let select =
        try parse(select: "SELECT * FROM T WHERE Name LIKE 'a\\%' ESCAPE '\\'")
    #expect(select.predicate
                == .like(.column("Name"),
                         pattern: .expression(.literal(.string("a\\%"))),
                         escape: .expression(.literal(.string("\\"))),
                         negated: false))
  }

  @Test func `parses a LIKE over an expression pattern`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Name LIKE Name")
    #expect(select.predicate
                == .like(.column("Name"),
                         pattern: .expression(.column("Name")),
                         escape: nil, negated: false))
  }

  @Test func `parses a LIKE with a bound pattern`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Name LIKE :pattern")
    #expect(select.predicate
                == .like(.column("Name"), pattern: .parameter("pattern"),
                         escape: nil, negated: false))
  }

  @Test func `parses a LIKE with a bound escape`() throws {
    let select = try parse(select:
        "SELECT * FROM T WHERE Name LIKE :pattern ESCAPE :e")
    #expect(select.predicate
                == .like(.column("Name"), pattern: .parameter("pattern"),
                         escape: .parameter("e"), negated: false))
  }
}

// MARK: - Matcher

struct LikeMatcherTests {
  @Test func `a percent matches any trailing run`() throws {
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'a%'",
                       yields: [[1], [2]])
  }

  @Test func `an underscore matches exactly one character`() throws {
    try names().expect("SELECT Id FROM T WHERE Name LIKE '_bc'", yields: [[1]])
  }

  @Test func `an underscore does not match the wrong length`() throws {
    // `'abc' LIKE 'a_'` is FALSE — `a_` matches a two-character string, and
    // every Name is three characters — so no row qualifies.
    try names().empty("SELECT Id FROM T WHERE Name LIKE 'a_'")
  }

  @Test func `a percent matches an interior run`() throws {
    // `a%c` backtracks: the `%` consumes `b`, then `c` anchors the tail.
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'a%c'", yields: [[1]])
  }

  @Test func `a percent matches the empty run`() throws {
    // `abc%` matches `abc` with the `%` consuming nothing.
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'abc%'", yields: [[1]])
  }

  @Test func `an empty pattern matches only the empty string`() throws {
    try Catalog {
      Relation("S", ["Id": .integer, "Name": .text]) {
        Row(1, "")
        Row(2, "a")
      }
    }.expect("SELECT Id FROM S WHERE Name LIKE ''", yields: [[1]])
  }

  @Test func `a bare pattern matches an exact string`() throws {
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'abc'", yields: [[1]])
  }
}

// MARK: - Escape

struct LikeEscapeTests {
  /// A single-row relation whose Name holds a literal `%`, so an escaped
  /// pattern must match it as a literal rather than a wildcard.
  private func literal() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "Name": .text]) {
        Row(1, "a%b")
        Row(2, "axb")
      }
    }
  }

  @Test func `an escaped percent matches a literal percent`() throws {
    // `'a%b' LIKE 'a\%b' ESCAPE '\'` — the escaped `%` matches a literal `%`,
    // so only row 1 (whose Name is `a%b`) qualifies, NOT row 2 (`axb`), which
    // an UNescaped `a%b` would also match.
    try literal().expect(
        "SELECT Id FROM T WHERE Name LIKE 'a\\%b' ESCAPE '\\'", yields: [[1]])
  }

  @Test func `an unescaped wildcard still matches under ESCAPE`() throws {
    // With an ESCAPE declared but a bare `%`, the `%` is still a wildcard, so
    // both rows match `a%b`.
    try literal().expect("SELECT Id FROM T WHERE Name LIKE 'a%b' ESCAPE '\\'",
                         yields: [[1], [2]])
  }

  @Test func `an escaped underscore matches a literal underscore`() throws {
    try Catalog {
      Relation("U", ["Id": .integer, "Name": .text]) {
        Row(1, "a_b")
        Row(2, "axb")
      }
    }.expect("SELECT Id FROM U WHERE Name LIKE 'a\\_b' ESCAPE '\\'",
             yields: [[1]])
  }

  @Test func `a non-character ESCAPE faults`() throws {
    // ISO requires the escape to be a single character; a multi-character one
    // is `SQLError.argument` at evaluation.
    try names().expect(
        "SELECT Id FROM T WHERE Name LIKE 'a%' ESCAPE 'xy'",
        fails: .argument("LIKE ESCAPE must be a single character"))
  }
}

// MARK: - Three-valued logic

struct LikeThreeValuedTests {
  @Test func `a NULL operand makes LIKE UNKNOWN`() throws {
    // Row 4's Name is NULL, so `NULL LIKE 'a%'` is UNKNOWN — the row is dropped
    // rather than admitted, and NOT LIKE does not admit it either.
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'a%'",
                       yields: [[1], [2]])
    try names().expect("SELECT Id FROM T WHERE Name NOT LIKE 'a%'",
                       yields: [[3]])
  }

  @Test func `a NULL pattern makes LIKE UNKNOWN`() throws {
    // A NULL pattern makes every row UNKNOWN, so no row is admitted — under
    // either LIKE or NOT LIKE.
    try Catalog {
      Relation("N", ["Id": .integer, "P": .text]) {
        Row(1, nil)
      }
    }.empty("SELECT Id FROM N WHERE 'abc' LIKE P")
    try Catalog {
      Relation("N", ["Id": .integer, "P": .text]) {
        Row(1, nil)
      }
    }.empty("SELECT Id FROM N WHERE 'abc' NOT LIKE P")
  }

  @Test func `NOT LIKE negates the match`() throws {
    // Rows whose non-NULL Name does not begin `a`; row 4 (NULL) is UNKNOWN and
    // dropped.
    try names().expect("SELECT Id FROM T WHERE Name NOT LIKE 'a%'",
                       yields: [[3]])
  }

  @Test func `a non-character operand faults the run`() throws {
    // `K` is an integer column, so `K LIKE '10'` has a non-character operand:
    // ISO `LIKE` requires character operands, so the run faults 42804 rather
    // than the old silent FALSE (which admitted every row under `NOT LIKE`).
    try names().expect("SELECT Id FROM T WHERE K LIKE '10'",
                       fails: .state("42804",
                                     "LIKE requires character operands"))
  }
}

// MARK: - Type checking

struct LikeTypeCheckingTests {
  @Test func `a non-character operand faults the schema check`() throws {
    // `K` is an integer column: `K LIKE '10'` has a non-character operand, so
    // the schema check faults 42804 (ISO `LIKE` requires character operands),
    // matching the run — run ≡ validate.
    let query = try parse(query: "SELECT Id FROM T WHERE K LIKE '10'")
    #expect(throws: SQLError.state("42804",
                                   "LIKE requires character operands")) {
      try names().columns(of: query, validate: true)
    }
  }

  @Test func `a bad operand expression faults the schema check`() throws {
    // The operand and pattern are still validated for REAL errors: `Name + 1`
    // is text arithmetic, which faults exactly as a run would.
    let query = try parse(query: "SELECT Id FROM T WHERE Name + 1 LIKE 'a%'")
    let resolve = { () throws -> Array<OutputColumn> in
      try names().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }
}

// MARK: - NULL pattern/escape parity

/// A constant-NULL `LIKE` pattern or escape makes the run UNKNOWN before its
/// non-character fallback, so validation must admit it without enforcing the
/// subject's character type — `K LIKE NULL` (integer `K`) runs and selects
/// nothing, it does not fault 42804. Only a non-NULL pattern over a
/// non-character subject faults, on both paths.
struct LikeNullOperandTests {
  @Test func `a NULL pattern admits a non-character subject on both paths`()
      throws {
    // `K` is integer; a constant-NULL pattern reads UNKNOWN regardless of `K`,
    // so the run selects nothing and validation admits it — no 42804, matching
    // the run. adversarial: enforcing the subject type first faults validation.
    let query = try parse(query: "SELECT Id FROM T WHERE K LIKE NULL")
    _ = try names().columns(of: query, validate: true)
    try names().empty("SELECT Id FROM T WHERE K LIKE NULL")
  }

  @Test func `a NULL escape admits a non-character subject on both paths`()
      throws {
    // A constant-NULL escape is UNKNOWN before the non-character fallback, so
    // `K LIKE 'x' ESCAPE NULL` (integer `K`) admits at validation and selects
    // no rows at run — the run ≡ validate parity the NULL-first ordering keeps.
    let query =
        try parse(query: "SELECT Id FROM T WHERE K LIKE 'x' ESCAPE NULL")
    _ = try names().columns(of: query, validate: true)
    try names().empty("SELECT Id FROM T WHERE K LIKE 'x' ESCAPE NULL")
  }

  @Test func `a non-NULL pattern still faults a non-character subject`()
      throws {
    // With a non-NULL pattern the run reaches its non-character fallback, so
    // `K LIKE 'x'` (integer `K`) faults 42804 at run and validation — the NULL
    // exemption does not weaken the ordinary character-type enforcement.
    let fault = SQLError.state("42804", "LIKE requires character operands")
    let query = try parse(query: "SELECT Id FROM T WHERE K LIKE 'x'")
    #expect(throws: fault) { try names().columns(of: query, validate: true) }
    try names().expect("SELECT Id FROM T WHERE K LIKE 'x'", fails: fault)
  }

  @Test func `a character subject with a NULL pattern stays UNKNOWN`() throws {
    // A genuine character subject `Name LIKE NULL` admits at validation and is
    // UNKNOWN for every row at run — the NULL-pattern short-circuit is not
    // limited to a non-character subject.
    let query = try parse(query: "SELECT Id FROM T WHERE Name LIKE NULL")
    _ = try names().columns(of: query, validate: true)
    try names().empty("SELECT Id FROM T WHERE Name LIKE NULL")
  }
}

// MARK: - NULL subject parity

/// A constant-NULL `LIKE` subject makes the run's `like` return UNKNOWN from
/// its `(.null, _, _)` arm before it inspects the pattern's type, so neither
/// the subject nor the pattern character type is enforced — `NULL LIKE 1` runs
/// and selects nothing, it does not fault 42804. Symmetric to the constant-NULL
/// pattern exemption `LikeNullOperandTests` covers; only a non-NULL
/// non-character subject reaches the character check the run's non-character
/// fallback faults.
struct LikeNullSubjectTests {
  @Test func `a NULL subject with a non-character pattern does not fault`()
      throws {
    // `NULL LIKE 1`: the NULL subject short-circuits the run to UNKNOWN before
    // the integer pattern's type is inspected, so it selects nothing and does
    // not fault — the strict validate path must agree. adversarial: enforcing
    // the pattern's character type first faults validation.
    let query = try parse(query: "SELECT Id FROM T WHERE NULL LIKE 1")
    _ = try names().columns(of: query, validate: true)
    try names().empty("SELECT Id FROM T WHERE NULL LIKE 1")
  }

  @Test func `a non-NULL non-character subject still faults`() throws {
    // The skip is scoped to a NULL subject; a non-null integer subject `K` is a
    // non-character operand the run's `like` faults, so `K LIKE 1` still faults
    // 42804 on both paths — the exemption does not over-suppress.
    let fault = SQLError.state("42804", "LIKE requires character operands")
    let query = try parse(query: "SELECT Id FROM T WHERE K LIKE 1")
    #expect(throws: fault) { try names().columns(of: query, validate: true) }
    try names().expect("SELECT Id FROM T WHERE K LIKE 1", fails: fault)
  }
}

// MARK: - Parameter pattern/escape parity

/// A `:parameter` `LIKE` pattern or escape carries a per-run value from the
/// bindings — possibly NULL or unbound — so the run reads it as UNKNOWN before
/// its non-character fallback unless a non-NULL non-character value is bound.
/// Validation cannot know the binding, so it defers the subject's (and
/// pattern's) character type to the run exactly as it defers a constant-NULL
/// pattern: `K LIKE :p` (integer `K`) does not fault at validation, and at run
/// an unbound or NULL `:p` selects nothing while a non-character-bound one
/// faults 42804 — the run is the authority for the per-run kind. The strict
/// validator (commit 1) must agree without the comparison-finder.
struct LikeParameterOperandTests {
  @Test func `a parameter pattern admits a non-character subject at validate`()
      throws {
    // `K` is integer; a `:pattern` operand has no binding at validate time, so
    // enforcing the subject's character type would reject `K LIKE :pattern` a
    // run keeps. Validation admits it, deferring to the run — no 42804.
    let query = try parse(query: "SELECT Id FROM T WHERE K LIKE :pattern")
    _ = try names().columns(of: query, validate: true)
  }

  @Test func `an unbound parameter pattern selects nothing at run`() throws {
    // An unbound `:pattern` resolves to NULL, so `K LIKE :pattern` is UNKNOWN
    // for every row before the integer subject's type is inspected — the run
    // selects nothing and does not fault, matching the admitting validation.
    try names().empty("SELECT Id FROM T WHERE K LIKE :pattern")
  }

  @Test func `a parameter escape admits a non-character subject at validate`()
      throws {
    // A `:escape` operand likewise has no binding at validate time, so
    // `K LIKE 'x' ESCAPE :escape` (integer `K`) admits without enforcing the
    // subject's character type — deferred to the run.
    let query =
        try parse(query: "SELECT Id FROM T WHERE K LIKE 'x' ESCAPE :escape")
    _ = try names().columns(of: query, validate: true)
  }

  @Test func `an unbound parameter escape selects nothing at run`() throws {
    // An unbound `:escape` resolves to NULL, an UNKNOWN escape, so
    // `K LIKE 'x' ESCAPE :escape` selects nothing at run before the integer
    // subject's type is reached — no 42804, matching validation.
    try names().empty("SELECT Id FROM T WHERE K LIKE 'x' ESCAPE :escape")
  }

  @Test func `a non-character bound parameter pattern faults the run`() throws {
    // The run is the authority for the per-run kind: a `:pattern` bound to a
    // non-null integer makes `K LIKE :pattern` reach the non-character fallback
    // on the first row, faulting 42804 exactly as `K LIKE 1` does. Validation
    // deferred it (the binding is unknown at compile), so the run decides.
    let fault = SQLError.state("42804", "LIKE requires character operands")
    try names().expect("SELECT Id FROM T WHERE K LIKE :pattern",
                       fails: fault, bindings: ["pattern": .integer(1)])
  }

  @Test func `a text bound parameter pattern still matches`() throws {
    // A `:pattern` bound to text runs as an ordinary pattern: `Name LIKE :p`
    // with `:p` = `'ab%'` matches the two `ab`-prefixed rows — the deferral
    // does not disturb a well-typed bound pattern.
    try names().expect("SELECT Id FROM T WHERE Name LIKE :pattern",
                       yields: [[1], [2]],
                       bindings: ["pattern": .text("ab%")])
  }
}

// MARK: - Pushdown safety

/// Whether `plan` reaches a `.scan` carrying a seek boundary — the observable
/// consequence of a `safe` conjunct riding down to its base scan.
private func seeks(_ plan: Plan) -> Bool {
  switch plan {
  case let .scan(_, _, seek): seek != nil
  case let .select(_, source): seeks(source)
  case let .project(_, source): seeks(source)
  case let .sort(_, source): seeks(source)
  case let .limit(_, _, source): seeks(source)
  case let .distinct(source): seeks(source)
  case let .aggregate(_, _, source): seeks(source)
  case let .derived(_, sub, _, _): seeks(sub)
  case let .product(left, right): seeks(left) || seeks(right)
  case let .join(outer, _, _, _, _, _, _): seeks(outer)
  case let .outer(left, right, _, _): seeks(left) || seeks(right)
  case let .semijoin(left, right, _, _): seeks(left) || seeks(right)
  case let .apply(left, _, _, _, _, _): seeks(left)
  case let .setop(_, left, right, _, _, _): seeks(left) || seeks(right)
  case .single, .empty: false
  }
}

/// Whether `plan` reaches a `.join` — a hash join formed from an `ON` whose
/// every conjunct is safe, extracting an equi key.
private func joins(_ plan: Plan) -> Bool {
  switch plan {
  case .join: true
  case let .select(_, source): joins(source)
  case let .project(_, source): joins(source)
  case let .sort(_, source): joins(source)
  case let .limit(_, _, source): joins(source)
  case let .distinct(source): joins(source)
  case let .aggregate(_, _, source): joins(source)
  case let .derived(_, sub, _, _): joins(sub)
  case let .product(left, right): joins(left) || joins(right)
  case let .outer(left, right, _, _): joins(left) || joins(right)
  case let .semijoin(left, right, _, _): joins(left) || joins(right)
  case let .apply(left, _, _, _, _, _): joins(left)
  case let .setop(_, left, right, _, _, _): joins(left) || joins(right)
  case .single, .empty, .scan: false
  }
}

/// Whether `plan` reaches a `.select` standing directly over a `.product` — the
/// residual product-under-select a join forms when an unsafe `ON` conjunct bars
/// hash-key extraction, so the whole `ON` is evaluated per pair.
private func residual(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .product): true
  case let .select(_, source): residual(source)
  case let .project(_, source): residual(source)
  case let .sort(_, source): residual(source)
  case let .limit(_, _, source): residual(source)
  case let .distinct(source): residual(source)
  case let .aggregate(_, _, source): residual(source)
  case let .derived(_, sub, _, _): residual(sub)
  case let .product(left, right): residual(left) || residual(right)
  case let .join(outer, _, _, _, _, _, _): residual(outer)
  case let .outer(left, right, _, _): residual(left) || residual(right)
  case let .semijoin(left, right, _, _): residual(left) || residual(right)
  case let .apply(left, _, _, _, _, _): residual(left)
  case let .setop(_, left, right, _, _, _): residual(left) || residual(right)
  case .single, .empty, .scan: false
  }
}

/// Whether `plan` is (or reaches through unary operators) a `.select` — a
/// filter standing over a source, the shape a conjunct kept out of a pushdown
/// leaves behind.
private func floats(_ plan: Plan) -> Bool {
  switch plan {
  case .select: true
  case let .project(_, source): floats(source)
  case let .sort(_, source): floats(source)
  case let .limit(_, _, source): floats(source)
  case let .derived(_, sub, _, _): floats(sub)
  default: false
  }
}

/// The `LIKE` escape's effect on `safe`, hence on pushdown/seek/join-reorder
/// eligibility: a `.like` is `safe` (may ride below a seek or join) only when
/// its escape is absent OR statically a single-character text constant, because
/// `Row.like` faults on any other escape independently of whether a pair
/// matches — so a hash join must not drop a non-matching pair (nor a seek a
/// narrowed run) before that fault fires.
struct LikeSafetyTests {
  /// A two-relation fixture for the `ON`-residual reordering hazard: `A` has
  /// one row whose join key `K` is NULL (so the equi `A.K = B.K` is UNKNOWN,
  /// not a definite FALSE that would short-circuit the Kleene `AND` before the
  /// escaped LIKE ran) and whose escape column `E` is a multi-character text
  /// (an invalid escape). A hash key would DROP the NULL-key pair before the
  /// escaped `LIKE` faults, hiding the fault; keeping the whole `ON` a residual
  /// over the pair runs the LIKE and faults.
  private func mismatched() throws -> FixtureCatalog {
    try Catalog {
      Relation("A", ["K": .integer, "Name": .text, "E": .text]) {
        Row(nil, "abc", "xy")
      }
      Relation("B", ["K": .integer]) {
        Row(2)
      }
    }
  }

  @Test func `a non-constant escape is unsafe and bars ON key extraction`()
      throws {
    // `ON A.K = B.K AND A.Name LIKE 'a%' ESCAPE A.E`, `A.E` a multi-character
    // slot — an escape that faults regardless of the pair. Unsafe, it bars the
    // equi from becoming a hash key: `nest` forms no `.join`, the level is a
    // residual `.select` over the `.product`, so the whole `ON` runs per pair.
    let compiled = try mismatched().compile(parse(query: """
        SELECT A.K FROM A JOIN B ON A.K = B.K AND A.Name LIKE 'a%' ESCAPE A.E
        """))
    let plan = try mismatched().optimise(compiled.pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a non-constant escape faults even against a non-matching pair`()
      throws {
    // The same `ON A.K = B.K AND A.Name LIKE 'a%' ESCAPE A.E` run against the
    // single pair (`A.K` NULL, `B.K = 2`). The equi is UNKNOWN, so the Kleene
    // `AND` does not short-circuit and evaluates the LIKE. Because the escaped
    // LIKE is unsafe, no key is hoisted and the residual runs the whole `ON`
    // per pair, so the invalid escape faults `SQLError.argument` — where
    // marking it safe would extract the key, drop the NULL-key pair, and hide
    // the fault (return no rows).
    try mismatched().expect("""
        SELECT A.K FROM A JOIN B ON A.K = B.K AND A.Name LIKE 'a%' ESCAPE A.E
        """,
        fails: .argument("LIKE ESCAPE must be a single character"))
  }

  @Test func `a constant multi-character escape is unsafe and faults`() throws {
    // A constant escape that is a text but NOT a single character (`ESCAPE
    // 'ab'`) is likewise unsafe — it faults regardless of the pair — so it too
    // bars key extraction (a residual `.select` over the `.product`, no
    // `.join`) and the residual faults against the NULL-key pair rather than a
    // hash key dropping it.
    let sql = """
        SELECT A.K FROM A JOIN B ON A.K = B.K AND A.Name LIKE 'a%' ESCAPE 'ab'
        """
    let compiled = try mismatched().compile(parse(query: sql))
    let plan = try mismatched().optimise(compiled.pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
    try mismatched().expect(sql,
        fails: .argument("LIKE ESCAPE must be a single character"))
  }

  @Test func `a constant single-character escape is safe and may be sought`()
      throws {
    // `WHERE Name LIKE '_%' ESCAPE '\' AND Id = 2` over an Id-sorted relation:
    // the escape is a static single-character constant, so the LIKE is safe and
    // does not bar the seekable `Id = 2` from riding down to the base scan.
    let catalog = try Catalog {
      Relation("S", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "abc")
        Row(2, "xyz")
      }
    }
    let compiled = try catalog.compile(parse(query: """
        SELECT Id FROM S WHERE Name LIKE '_%' ESCAPE '\\' AND Id = 2
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(seeks(plan))

    // …and it still matches correctly: only row 2 has `Id = 2`, and its
    // three-character Name matches `_%` (one character then any run).
    try catalog.expect("""
        SELECT Id FROM S WHERE Name LIKE '_%' ESCAPE '\\' AND Id = 2
        """, yields: [[2]])
  }

  @Test func `a plain LIKE with no escape stays safe and may be sought`()
      throws {
    // A plain `LIKE` (no escape) never faults — a non-text operand or pattern
    // is a definite non-match and a NULL is UNKNOWN — so it stays safe: the
    // seekable `Id = 2` still rides down to the base scan beside it.
    let catalog = try Catalog {
      Relation("S", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "abc")
        Row(2, "xyz")
      }
    }
    let compiled = try catalog.compile(parse(query: """
        SELECT Id FROM S WHERE Name LIKE 'x%' AND Id = 2
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(seeks(plan))
    try catalog.expect("SELECT Id FROM S WHERE Name LIKE 'x%' AND Id = 2",
                       yields: [[2]])
  }
}

// MARK: - Bound pattern

struct LikeBoundTests {
  @Test func `a LIKE over a WHERE column returns the right rows`() throws {
    // The prefix wildcard exercises LIKE over a real column in a WHERE — rows 1
    // and 2 begin `ab`, row 3 does not, and row 4 (NULL) is UNKNOWN.
    try names().expect("SELECT Id FROM T WHERE Name LIKE 'ab%'",
                       yields: [[1], [2]])
  }

  @Test func `a column pattern matches per row`() throws {
    // The pattern is itself a column, evaluated per row: every non-NULL Name
    // matches itself, and row 4 (NULL on both sides) is UNKNOWN and dropped.
    try names().expect("SELECT Id FROM T WHERE Name LIKE Name",
                       yields: [[1], [2], [3]])
  }
}

// MARK: - Evaluation order

/// The operand, pattern, and escape are each evaluated once, IN ORDER, before
/// the three-valued NULL result is decided — so a fault in a reached operand
/// (`1 / K` with `K = 0`) surfaces rather than being swallowed by a NULL escape
/// that an early return would have turned into a silent UNKNOWN.
struct LikeEvaluationOrderTests {
  /// A relation whose K is `0` in one row (so `1 / K` faults) and whose escape
  /// column E is NULL, to exercise the faulting-operand-before-NULL-escape
  /// corner.
  private func faulting() throws -> FixtureCatalog {
    try Catalog {
      Relation("F", ["Id": .integer, "K": .integer, "E": .text]) {
        Row(1, 0, nil)
      }
    }
  }

  @Test func `a faulting operand surfaces before a NULL escape UNKNOWN`()
      throws {
    // `(1 / K) LIKE 'x' ESCAPE E` with `K = 0, E = NULL`. The operand `1 / K`
    // faults `SQLError.divide`; the executor must evaluate the reached operand
    // before deciding the NULL-escape UNKNOWN — an early return on the NULL
    // escape would silently FILTER the row (UNKNOWN) and hide the divide.
    // adversarial: reverting to early-return-on-NULL-escape stops this throw.
    try faulting().expect(
        "SELECT Id FROM F WHERE (1 / K) LIKE 'x' ESCAPE E",
        fails: .divide)
  }

  @Test func `a NULL escape with a safe operand is a clean UNKNOWN`() throws {
    // A plain safe operand under a NULL escape is UNKNOWN — the row is excluded
    // without a throw, so the eval-order fix does not turn every NULL escape
    // into a fault.
    try Catalog {
      Relation("F", ["Id": .integer, "Name": .text, "E": .text]) {
        Row(1, "x", nil)
      }
    }.empty("SELECT Id FROM F WHERE Name LIKE 'x' ESCAPE E")
  }
}

// MARK: - Static escape validation

/// A statically-invalid ESCAPE (a constant that is not a single-character text)
/// is rejected at validation (`columns(of:validate:)`), not left to fault on
/// every row — `check` folds a row-independent escape and rejects a bad one.
struct LikeEscapeValidationTests {
  @Test func `a constant multi-character escape faults validation`() throws {
    // `ESCAPE 'xy'` is a constant text of the wrong length — un-runnable — so
    // `columns(of:validate:)` rejects it at validation with the run's message.
    // adversarial: reverting the check drops this validation throw.
    let query = try parse(query:
        "SELECT Id FROM T WHERE Name LIKE 'x' ESCAPE 'xy'")
    #expect(throws:
        SQLError.argument("LIKE ESCAPE must be a single character")) {
      try names().columns(of: query, validate: true)
    }
  }

  @Test func `a constant non-text escape faults validation`() throws {
    // `ESCAPE 1` is a constant integer — never a valid escape — so it too is
    // rejected at validation rather than faulting per row.
    let query = try parse(query:
        "SELECT Id FROM T WHERE Name LIKE 'x' ESCAPE 1")
    #expect(throws:
        SQLError.argument("LIKE ESCAPE must be a single character")) {
      try names().columns(of: query, validate: true)
    }
  }

  @Test func `a valid single-character escape validates`() throws {
    // `ESCAPE '\'` is a valid single-character constant, so it validates.
    let query = try parse(query:
        "SELECT Id FROM T WHERE Name LIKE 'x' ESCAPE '\\'")
    _ = try names().columns(of: query, validate: true)
  }

  @Test func `a non-constant escape validates`() throws {
    // A column escape is per row and cannot be checked statically, so
    // validation accepts it (the run validates it) — here `Name` stands in as
    // a non-constant escape term.
    let query = try parse(query:
        "SELECT Id FROM T WHERE Name LIKE 'x' ESCAPE Name")
    _ = try names().columns(of: query, validate: true)
  }
}

// MARK: - Matcher complexity

/// The matcher is linear (a two-pointer scan), not the exponential
/// backtracking recursion — so a pathological pattern against a long run of
/// its wildcard fill returns promptly rather than pegging the engine.
struct LikeComplexityTests {
  @Test func `a pathological pattern returns false promptly`() throws {
    // `%a%a%a%a%a%a%a%b` against a long run of `a`s (no `b`) is the classic
    // ReDoS-style blowup for a per-split recursive matcher — combinatorial in
    // the number of `%` splits over the text length. The linear scan decides
    // FALSE in O(n·m) and returns at once. adversarial: the recursive matcher
    // does not complete in bounded time on this input.
    let text = String(repeating: "a", count: 256)
    #expect(!matches(text, "%a%a%a%a%a%a%a%b", escape: nil))
  }

  @Test func `a pathological pattern that matches returns true promptly`()
      throws {
    // The same shape with a trailing `a` the final literal can anchor matches,
    // and still linearly.
    let text = String(repeating: "a", count: 256)
    #expect(matches(text, "%a%a%a%a%a%a%a%a", escape: nil))
  }
}

// MARK: - Bound parameter

/// A `LIKE` pattern or escape may be a `:parameter` resolved from the bindings
/// at eval — the same mechanism `Filter.bound` uses for a comparison's right
/// operand — so a caller binds a pattern rather than interpolating it.
struct LikeParameterTests {
  @Test func `a bound pattern matches the right rows`() throws {
    // `WHERE Name LIKE :pattern` bound to `'a%'` — rows 1 and 2 begin `a`, row
    // 3 does not, row 4 (NULL) is UNKNOWN. adversarial: reverting the parser
    // `:param` handling makes `LIKE :pattern` fail to parse/bind.
    try names().expect("SELECT Id FROM T WHERE Name LIKE :pattern",
                       yields: [[1], [2]],
                       bindings: ["pattern": .text("a%")])
  }

  @Test func `a bound escape binds`() throws {
    // `WHERE Name LIKE :pattern ESCAPE :e`, the pattern an escaped literal `%`
    // and `:e` the escape `\`, so only the row whose Name holds a literal `%`
    // matches.
    try Catalog {
      Relation("T", ["Id": .integer, "Name": .text]) {
        Row(1, "a%b")
        Row(2, "axb")
      }
    }.expect("SELECT Id FROM T WHERE Name LIKE :pattern ESCAPE :e",
             yields: [[1]],
             bindings: ["pattern": .text("a\\%b"), "e": .text("\\")])
  }

  @Test func `an unbound pattern is UNKNOWN`() throws {
    // `:pattern` with no binding resolves to NULL, so every row is UNKNOWN and
    // none is admitted — as an unbound comparison `:parameter` does.
    try names().empty("SELECT Id FROM T WHERE Name LIKE :pattern")
  }

  @Test func `a NULL-bound pattern is UNKNOWN`() throws {
    // `:pattern` bound to NULL is likewise UNKNOWN — no row is admitted.
    try names().empty("SELECT Id FROM T WHERE Name LIKE :pattern",
                      bindings: ["pattern": .null])
  }

  @Test func `a bound escape is unsafe and bars a seek`() throws {
    // A `:parameter` escape is not a static single-character constant — it may
    // be unbound, NULL, or the wrong length at run time — so the escaped LIKE
    // is unsafe and does not ride below a seek: the seekable `Id = 2` cannot
    // reach the base scan beside it.
    let catalog = try Catalog {
      Relation("S", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "abc")
        Row(2, "xyz")
      }
    }
    guard case let .select(query) =
        try Statement(parsing: """
            SELECT Id FROM S WHERE Name LIKE 'x%' ESCAPE :e AND Id = 2
            """) else {
      Issue.record("expected a SELECT statement")
      return
    }
    let compiled = try catalog.compile(query)
    let plan = try catalog.optimise(compiled.pushdown(),
                                    ["e": .text("\\")])
    #expect(!seeks(plan))
  }
}

// MARK: - Parameterised classification

/// A parameterised `LIKE` — one whose pattern or escape operand is a run-time
/// `:parameter` — reads no slot yet can be UNKNOWN (the parameter may be
/// unbound or bound to NULL), so `nullable` counts it and pushdown must not
/// ride it below a later unsafe conjunct: the non-short-circuiting `AND` still
/// owes that conjunct's evaluation after an UNKNOWN left.
struct LikeParameterisedTests {
  /// A view over a single (x = 1, y = 0) row — the derived-leaf shape the
  /// slotless-conjunct pushdown hazard needs, so a conjunct kept out of the
  /// view floats above the leaf rather than being injected below it.
  private func maybe() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer, "y": .integer]) {
        Row(1, 0)
      }
      try View("V", "SELECT x, y FROM T", as: ["x", "y"])
    }
  }

  @Test func `a parameterised LIKE is nullable`() throws {
    // A `.like` whose pattern operand is a `:parameter` reads no slot yet is
    // nullable — the pattern may be unbound or NULL, making the LIKE UNKNOWN.
    let pattern = Filter.like(.constant(.text("x")),
                              pattern: .parameter("p"), escape: nil,
                              negated: false)
    #expect(pattern.nullable)

    // An escape `:parameter` counts the same, whatever the pattern.
    let escape = Filter.like(.constant(.text("x")),
                             pattern: .term(.constant(.text("y"))),
                             escape: .parameter("e"), negated: false)
    #expect(escape.nullable)
  }

  @Test func `a constant LIKE is not nullable`() throws {
    // A `.like` over constant operands alone — no `:parameter` and no slot —
    // is definite, so it stays eligible for pushdown.
    let filter = Filter.like(.constant(.text("x")),
                             pattern: .term(.constant(.text("y"))),
                             escape: nil, negated: false)
    #expect(!filter.nullable)
  }

  @Test func `a parameterised LIKE is not pushed below a later unsafe conjunct`()
      throws {
    // `SELECT x FROM V WHERE 'x' LIKE :p AND (1 / y) = 0` with `:p` unbound:
    // the outer `AND` does not short-circuit, so on the (y = 0) row the UNKNOWN
    // LIKE still runs the division, which raises. Injecting the slotless `'x'
    // LIKE :p` into the view would drop every row first, suppressing the
    // throw — so a parameterised LIKE is nullable and must stay outer.
    let catalog = try maybe()
    let compiled = try catalog.compile(parse(query: """
        SELECT x FROM V WHERE 'x' LIKE :p AND (1 / y) = 0
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])

    // The parameterised LIKE floats above the derived leaf rather than riding
    // into the view below the unsafe division.
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    catalog.expect("SELECT x FROM V WHERE 'x' LIKE :p AND (1 / y) = 0",
                   fails: .divide)
  }

  @Test func `a constant LIKE is pushed below a later unsafe conjunct`() throws {
    // control: `'x' LIKE 'y'` names no `:parameter`, so it is definite and
    // eligible for the normal pushdown — a non-nullable conjunct injects into
    // the view, dropping every row before the outer division runs, so the query
    // returns nothing rather than raising (the ordinary non-parameterised way).
    let catalog = try maybe()
    try catalog.empty("SELECT x FROM V WHERE 'x' LIKE 'y' AND (1 / y) = 0")
  }
}
