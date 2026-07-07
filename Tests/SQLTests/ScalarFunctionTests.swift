// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

/// The catalog the ISO string-function tests project `POSITION` and `OVERLAY`
/// over. Its columns give each function an argument of the right type — `Text`
/// and `Sub` are TEXT, `Start` and `Len` are INTEGER — and a second row of NULL
/// in each so a call over a column and a call over a NULL both run. The third
/// row carries `Int.min` in `Start`/`Len` so the guarded 1-based-index and
/// length arithmetic is exercised at the edge where a naive `start - 1` or
/// `head + length` would overflow and trap.
private func library() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["Id": .integer, "Text": .text, "Sub": .text,
                   "Start": .integer, "Len": .integer]) {
      Row(1, "abcabc", "bc", 3, 2)
      Row(2, nil, nil, nil, nil)
      Row(3, "hello", "", Int.min, Int.min)
    }
  }
}

@Suite struct PositionTests {
  @Test func `POSITION declares its standard signature`() {
    #expect(Routines.standard["position"]?.returns == .integer)
    #expect(Routines.standard["position"]?.parameters == [.text, .text])
    #expect(Routines.standard["position"]?.deterministic == true)
  }

  @Test func `POSITION reports a 1-based occurrence`() throws {
    // 'bc' first occurs at character 2 of 'abcabc'.
    try library().expect("SELECT POSITION('bc' IN Text) FROM S WHERE Id = 1",
                         yields: [[2]], routines: .standard)
  }

  @Test func `POSITION reports 0 when the substring is absent`() throws {
    try library().expect("SELECT POSITION('zz' IN Text) FROM S WHERE Id = 1",
                         yields: [[0]], routines: .standard)
  }

  @Test func `POSITION reports 1 for an empty substring`() throws {
    // The empty string is a prefix of every string, so it occurs at 1 (ISO).
    try library().expect("SELECT POSITION('' IN Text) FROM S WHERE Id = 1",
                         yields: [[1]], routines: .standard)
    // The empty-column substring over the empty string is 1 too.
    try library().expect("SELECT POSITION(Sub IN Text) FROM S WHERE Id = 3",
                         yields: [[1]], routines: .standard)
  }

  @Test func `POSITION is case-sensitive`() throws {
    // 'BC' does not occur in the lower-cased 'abcabc'.
    try library().expect("SELECT POSITION('BC' IN Text) FROM S WHERE Id = 1",
                         yields: [[0]], routines: .standard)
  }

  @Test func `POSITION does not find an oversized substring`() throws {
    // A needle longer than the haystack cannot occur; the length guard reports
    // 0 rather than indexing out of bounds.
    try library().expect("SELECT POSITION('helloworld' IN Text) FROM S "
                             + "WHERE Id = 3",
                         yields: [[0]], routines: .standard)
  }

  @Test func `POSITION propagates NULL`() throws {
    try library().expect("SELECT POSITION('bc' IN Text) FROM S WHERE Id = 2",
                         yields: [[nil]], routines: .standard)
    try library().expect("SELECT POSITION(Sub IN 'abc') FROM S WHERE Id = 2",
                         yields: [[nil]], routines: .standard)
  }

  @Test func `POSITION faults on the wrong argument count`() throws {
    // The desugaring is a two-argument call; a delimited `"position"` reaches
    // the routine as an ordinary comma call, so a three-argument call trips the
    // routine's own arity check rather than the IN-syntax production.
    try library().expect(
        "SELECT \"position\"('a', 'b', 'c') FROM S WHERE Id = 1",
        fails: .argument("POSITION takes two arguments"), routines: .standard)
  }

  @Test func `POSITION faults on a non-text argument`() throws {
    try library().expect("SELECT POSITION('a' IN Start) FROM S WHERE Id = 1",
                         fails: .argument("POSITION requires text arguments"),
                         routines: .standard)
  }
}

/// A non-deterministic text routine's backing counter: each call returns a
/// distinct string whose LENGTH grows — "XX", then "XXX", … — so a double
/// evaluation is observable both in the call count and in the result. The
/// engine evaluates a row's projection on one thread, so no lock is needed.
private final class Talker: @unchecked Sendable {
  private(set) var count = 0

  /// Returns the next string (`"XX"`, `"XXX"`, …) and advances the count.
  func next() -> String {
    defer { count += 1 }
    return String(repeating: "X", count: 2 + count)
  }
}

@Suite struct OverlayTests {
  @Test func `OVERLAY declares its standard signature`() {
    #expect(Routines.standard["overlay"]?.returns == .text)
    #expect(Routines.standard["overlay"]?.parameters
                == [.text, .text, .integer, .integer])
    // The fourth `length` is optional — an omitted `FOR` runs the
    // three-argument form the routine defaults from its replacement.
    #expect(Routines.standard["overlay"]?.minimum == 3)
    #expect(Routines.standard["overlay"]?.deterministic == true)
  }

  @Test func `OVERLAY replaces FOR-many characters`() throws {
    // Replace 2 characters of 'abcabc' from position 3 ('ca') with 'XY'.
    try library().expect(
        "SELECT OVERLAY('abcabc' PLACING 'XY' FROM 3 FOR 2) FROM S "
            + "WHERE Id = 1",
        yields: [["abXYbc"]], routines: .standard)
  }

  @Test func `OVERLAY defaults its length to the replacement`() throws {
    // With no FOR, ISO removes as many characters as the replacement holds:
    // 'XYZ' is three long, so three characters of 'abcabc' from 3 ('cab') go.
    try library().expect(
        "SELECT OVERLAY('abcabc' PLACING 'XYZ' FROM 3) FROM S WHERE Id = 1",
        yields: [["abXYZc"]], routines: .standard)
  }

  @Test func `OVERLAY evaluates its replacement once without FOR`() throws {
    // With `FOR` omitted the default length is the replacement's own character
    // count — computed by the routine from the SINGLE evaluated replacement, so
    // the replacement is evaluated EXACTLY ONCE. `talker()` is
    // non-deterministic (unfoldable) and returns a longer string on each call;
    // evaluated once it inserts "XX" (2 long) and removes 2 characters of
    // 'abcdef' from position 2 ('bc') → "aXXdef", the counter reading 1. The
    // old desugar to `char_length(replacement)` referenced the replacement a
    // SECOND time — inserting one value but removing the length of a DIFFERENT
    // later one — so this guards that regression.
    let counter = Talker()
    let routines = try Routines.standard
        .registering("talker", returns: .text, deterministic: false) { _ in
          .text(counter.next())
        }
    try library().expect(
        "SELECT OVERLAY('abcdef' PLACING talker() FROM 2) FROM S WHERE Id = 1",
        yields: [["aXXdef"]], routines: routines)
    #expect(counter.count == 1)
  }

  @Test func `OVERLAY inserts when FOR is zero`() throws {
    // A zero length removes nothing, so the replacement is inserted before the
    // start position.
    try library().expect(
        "SELECT OVERLAY('abcabc' PLACING '--' FROM 3 FOR 0) FROM S "
            + "WHERE Id = 1",
        yields: [["ab--cabc"]], routines: .standard)
  }

  @Test func `OVERLAY over the columns replaces a computed span`() throws {
    // 'bc' placed into 'abcabc' from Start=3 FOR Len=2 replaces 'ca'.
    try library().expect(
        "SELECT OVERLAY(Text PLACING Sub FROM Start FOR Len) FROM S "
            + "WHERE Id = 1",
        yields: [["abbcbc"]], routines: .standard)
  }

  @Test func `OVERLAY clamps a start at or before 1 to the front`() throws {
    // A start of 0 or the extreme Int.min clamps to the first character; the
    // Int.min case would trap on a naive `start - 1`.
    try library().expect(
        "SELECT OVERLAY('abc' PLACING 'X' FROM 0 FOR 1) FROM S WHERE Id = 1",
        yields: [["Xbc"]], routines: .standard)
    try library().expect(
        "SELECT OVERLAY(Text PLACING 'X' FROM Start FOR 1) FROM S "
            + "WHERE Id = 3",
        yields: [["Xello"]], routines: .standard)
  }

  @Test func `OVERLAY clamps a start past the end to an append`() throws {
    try library().expect(
        "SELECT OVERLAY('abc' PLACING 'XY' FROM 99 FOR 1) FROM S "
            + "WHERE Id = 1",
        yields: [["abcXY"]], routines: .standard)
  }

  @Test func `OVERLAY clamps an oversized or negative length`() throws {
    // A length past the end removes only to the end; a negative length removes
    // nothing. The Int.min length exercises the overflow-safe capacity compare.
    try library().expect(
        "SELECT OVERLAY('abc' PLACING 'XY' FROM 2 FOR 99) FROM S "
            + "WHERE Id = 1",
        yields: [["aXY"]], routines: .standard)
    try library().expect(
        "SELECT OVERLAY('abc' PLACING 'XY' FROM 2 FOR 0 - 5) FROM S "
            + "WHERE Id = 1",
        yields: [["aXYbc"]], routines: .standard)
    try library().expect(
        "SELECT OVERLAY(Text PLACING 'X' FROM 1 FOR Len) FROM S WHERE Id = 3",
        yields: [["Xhello"]], routines: .standard)
  }

  @Test func `OVERLAY propagates NULL`() throws {
    try library().expect(
        "SELECT OVERLAY(Text PLACING 'X' FROM 1 FOR 1) FROM S WHERE Id = 2",
        yields: [[nil]], routines: .standard)
    try library().expect(
        "SELECT OVERLAY('abc' PLACING Sub FROM 1 FOR 1) FROM S WHERE Id = 2",
        yields: [[nil]], routines: .standard)
    try library().expect(
        "SELECT OVERLAY('abc' PLACING 'X' FROM Start) FROM S WHERE Id = 2",
        yields: [[nil]], routines: .standard)
  }

  @Test func `OVERLAY faults on the wrong argument count`() throws {
    // The routine's optional-tail arity accepts three or four arguments; a
    // delimited `"overlay"` reaches it as an ordinary comma call, so a
    // two-argument call trips the routine's own arity check rather than the
    // PLACING-syntax production.
    try library().expect(
        "SELECT \"overlay\"('a', 'b') FROM S WHERE Id = 1",
        fails: .argument("OVERLAY takes three or four arguments"),
        routines: .standard)
  }

  @Test func `OVERLAY faults on a non-text argument`() throws {
    try library().expect(
        "SELECT OVERLAY(Start PLACING 'X' FROM 1 FOR 1) FROM S WHERE Id = 1",
        fails: .argument("OVERLAY requires text, text, and integer "
                             + "arguments"),
        routines: .standard)
  }
}

/// Parses `text` as a single-projection `SELECT`'s expression, so the special
/// `POSITION`/`OVERLAY` syntax is checked to lower to the expected call.
private func lower(_ text: String) throws -> Expression {
  guard case let .select(.select(select)) =
      try Statement(parsing: "SELECT \(text) FROM S"),
      case let .expressions(projection) = select.projection,
      let first = projection.first else {
    Issue.record("expected a single projected expression")
    throw SQLError.incomplete(expected: "a projected expression")
  }
  return first.expression
}

@Suite struct ScalarSyntaxTests {
  @Test func `the lexer scans the OVERLAY keywords`() throws {
    var lexer = Lexer("PLACING FOR".utf8Span.span)
    var kinds = Array<Token.Kind>()
    while let token = try lexer.next() { kinds.append(token.kind) }
    #expect(kinds == [.placing, .for])
    var lower = Lexer("placing for".utf8Span.span)
    var folded = Array<Token.Kind>()
    while let token = try lower.next() { folded.append(token.kind) }
    #expect(folded == [.placing, .for])
  }

  @Test func `POSITION desugars to a two-argument call`() throws {
    #expect(try lower("POSITION('a' IN Text)")
                == .call(name: "position",
                         arguments: [.literal(.string("a")),
                                     .column("Text")]))
  }

  @Test func `OVERLAY with FOR desugars to a four-argument call`() throws {
    #expect(try lower("OVERLAY(Text PLACING 'a' FROM 1 FOR 2)")
                == .call(name: "overlay",
                         arguments: [.column("Text"),
                                     .literal(.string("a")),
                                     .literal(.integer(1)),
                                     .literal(.integer(2))]))
  }

  @Test func `OVERLAY without FOR desugars to a three-argument call`() throws {
    // No FOR ⇒ a THREE-argument call (no synthesized `char_length(replacement)`
    // fourth argument): the routine defaults the length from the once-evaluated
    // replacement, so the replacement is not referenced a second time.
    #expect(try lower("OVERLAY(Text PLACING 'ab' FROM 1)")
                == .call(name: "overlay",
                         arguments: [.column("Text"),
                                     .literal(.string("ab")),
                                     .literal(.integer(1))]))
  }

  @Test func `a delimited POSITION is an ordinary call name`() throws {
    // A double-quoted name is verbatim, so `"POSITION"(a, b)` is a plain call,
    // not the special IN syntax.
    #expect(try lower("\"POSITION\"('a', 'b')")
                == .call(name: "POSITION",
                         arguments: [.literal(.string("a")),
                                     .literal(.string("b"))]))
  }
}
