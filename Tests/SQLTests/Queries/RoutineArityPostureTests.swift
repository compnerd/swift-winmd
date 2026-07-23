// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Routine arity/existence posture

/// PINS the accepted run-vs-validate posture for a routine CALL: the bare
/// `run` path checks a routine EXISTS but defers arity/argument-type validation
/// to the strict `columns(of:validate:)` gate. A caller wanting strict checks
/// validates first; a run assumes the statement was already validated. This is
/// deliberate engine intent — a wrong-arity call reaches a run (a native
/// routine that does not self-check its count runs regardless), while
/// validation rejects it — so a regression that started faulting arity at run,
/// or stopped faulting it under validation, must break these tests.
///
/// The fixture is SELF-CONTAINED: a small local catalog and a locally
/// registered routine, disjoint from the shared `engine*` fixtures, so this
/// suite pins the posture independently.
@Suite struct RoutineArityPostureTests {
  /// A one-row catalog whose single INTEGER column a call projects over.
  private func table() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  /// Routines with a native `tally` declaring ONE integer parameter (arity 1)
  /// whose closure IGNORES its arguments and returns a constant. Because the
  /// closure does not self-check its argument count, a wrong-arity call reaches
  /// it and runs — isolating the run path's arity behaviour from a routine's
  /// own internal check (the standard `POSITION`/`BITAND` closures self-check,
  /// so
  /// they would fault regardless and could not observe the run-path posture).
  private func routines() throws(SQLError) -> Routines {
    try Routines()
        .registering("tally", parameters: [.integer]) { _ in .integer(42) }
  }

  @Test func `a wrong-arity call runs without an arity fault`() throws {
    // `tally` declares arity 1 but is called with ZERO arguments. The run path
    // checks only that `tally` EXISTS, not its arity, and the closure ignores
    // its arguments, so the call produces its constant rather than faulting.
    let catalog = try table()
    let routines = try routines()
    let query = try parse(query: "SELECT tally() FROM T WHERE Id = 1")
    let rows = try catalog.run(query, routines)
    #expect(rows == [[.integer(42)]])
  }

  @Test func `validation faults a wrong-arity call`() throws {
    // The SAME wrong-arity call is REJECTED by the strict validate gate: the
    // declared arity is checked against the supplied argument count, faulting
    // `.argument`. This is the gate a caller runs BEFORE a run when it wants
    // arity enforced.
    let catalog = try table()
    let routines = try routines()
    let query = try parse(query: "SELECT tally() FROM T WHERE Id = 1")
    let raised: SQLError?
    do {
      _ = try catalog.columns(of: query, routines: routines, validate: true)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised == .argument("tally takes 1 arguments"))
  }

  @Test func `an unknown routine faults on BOTH paths`() throws {
    // EXISTENCE is checked at run, unlike arity: an unregistered routine faults
    // `.function` at run AND under validation, so the distinction the posture
    // draws — existence checked, arity deferred — is explicit.
    let catalog = try table()
    let routines = try routines()
    let query = try parse(query: "SELECT nope() FROM T WHERE Id = 1")

    let ran: SQLError?
    do {
      _ = try catalog.run(query, routines)
      ran = nil
    } catch let fault {
      ran = fault
    }
    #expect(ran == .function("nope"))

    let validated: SQLError?
    do {
      _ = try catalog.columns(of: query, routines: routines, validate: true)
      validated = nil
    } catch let fault {
      validated = fault
    }
    #expect(validated == .function("nope"))
  }
}
