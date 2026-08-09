// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine
// Re-export SQLStandard so a test importing `SQLTestSupport` sees the
// prelude-defaulting `run`/`columns` overloads and `Routines.standard`; the
// fixtures default to the standard prelude, matching a run under `import SQL`.
@_exported import SQLStandard
import Testing

/// Expectation helpers that run a SQL query against a fixture catalog and check
/// its rows, forwarding the swift-testing source location so a failure points
/// at the call site rather than into this file.
///
/// `catalog.expect(_:yields:)` runs the query and checks the projected rows
/// against bare Swift literals a `ValueConvertible` lifts into `Value`s;
/// `catalog.empty(_:)` checks the query returns nothing; `catalog.expect(_:
/// fails:)` checks the query raises a given `SQLError`; and
/// `catalog.expect(_:equals:)` checks two queries return the same rows — the
/// pervasive "seek result equals scan result" idiom. Each is a `borrowing`
/// method on the catalog under test, takes a `location` defaulting to the
/// caller's, and runs through the engine's public `Catalog.run`, so the
/// framework needs no `@testable` import.

extension Catalog where Self: ~Escapable {
  /// Runs `sql` against this catalog through the given routines and bindings,
  /// asserting the `run ≡ validate` invariant on the run-faults path (issue
  /// #116): the validate path (`columns(of:validate:)`) must never advertise a
  /// schema for a query the run then *structurally* rejects.
  ///
  /// The forbidden state is directional: a run fault the schema derive is
  /// responsible for catching statically — an unknown relation/column/routine,
  /// a degree/arity mismatch, a non-comparable operand, a malformed or
  /// unsupported shape — must not coexist with a validate that *succeeded*. A
  /// data-dependent fault (division by zero, overflow, a scalar subquery's
  /// cardinality, a routine's own runtime check) is not a violation: validate
  /// has no rows and rightly succeeds while the run faults on the data, so the
  /// tripwire fires only when the run fault is `structural`.
  ///
  /// The check runs only with no bindings: the validate path deliberately
  /// skips a bound `x op :parameter` (`Scope.swift`), so a bound run may fault
  /// where the schema path correctly does not — expected, not a violation. The
  /// query the run already parsed is reused, and `columns(of:)` is asked with
  /// the same `routines`, so the two paths see one query and one prelude.
  ///
  /// A run through a native routine is exempt too (`native(_:)`): a
  /// host-registered closure or a defined `CREATE FUNCTION` body may itself
  /// throw a `structural`-classed fault for particular argument values, while
  /// `columns(of:)` validates the routine's declared signature without invoking
  /// the body and legitimately succeeds — an expected run/validate difference
  /// whose origin is the body, not a schema-derive hole, so the tripwire does
  /// not fire for a query carrying a non-standard routine.
  private borrowing func run(_ sql: String, routines: Routines,
                             bindings: Bindings,
                             location: Testing.SourceLocation)
      throws(SQLError) -> Array<Array<Value>> {
    let query = try parse(query: sql, location: location)
    do {
      return try run(query, routines, bindings: bindings)
    } catch let fault {
      if bindings.isEmpty, !Self.native(routines), Self.structural(fault),
         (try? columns(of: query, routines: routines, validate: true)) != nil {
        Issue.record("""
          run ≡ validate tripwire: validate accepted a query the run \
          structurally rejects. sql: \(sql); run fault: \(fault) \
          (\(fault.sqlstate))
          """, sourceLocation: location)
      }
      throw fault
    }
  }

  /// Whether `fault` is a fault the validate/schema path is responsible for
  /// catching statically — a structural, cardinality-independent fault — as
  /// opposed to a data-dependent fault a well-formed query legitimately raises
  /// only on actual row values.
  ///
  /// Structural faults (the tripwire fires when a run raises one while validate
  /// succeeded): the resolution faults a schema derive owns — an unknown
  /// relation/column/routine, an ambiguous or duplicate name, a degree/arity
  /// mismatch, a malformed or unsupported query shape, and the static
  /// grouping/distinct rules. The lexer/parser faults resolve before a query
  /// exists, so they never reach the tripwire; they are grouped here for
  /// completeness.
  ///
  /// Data-dependent faults (the tripwire does not fire — validate legitimately
  /// succeeds): a literal or arithmetic magnitude fault, a routine's rejected
  /// argument, division by zero, a recursive definition exceeding its iteration
  /// cap, and a scalar subquery's cardinality violation — each depends on
  /// actual values or row counts a schema derive has none of.
  ///
  /// Comparability (`42804`, the datatype-mismatch family — both the arithmetic
  /// `.operand` and the `.state("42804", …)` compare faults) is *not* firing.
  /// The schema check catches a direct cross-kind compare, so validate and run
  /// fault in parity there and the tripwire is never reached; but for a
  /// subquery / quantified / `IN (Q)` operand the schema check deliberately
  /// defers to the run (a subquery's single-column type may be a nominal-NULL
  /// placeholder — validate stays lenient, keeping the run the authority). That
  /// deferral is a documented soundness choice, not a run ≢ validate hole, so a
  /// `42804` run fault beside a succeeding validate is expected, not a
  /// violation.
  ///
  /// A `SQLSTATE` passthrough (`.state`) is otherwise classified by class: `42`
  /// (syntax or access-rule violation, less the deferred `42804`) and `0A`
  /// (feature not supported) are structural; class `22` (data exception), `54`
  /// (program limit), and `XX` (internal) are treated as data-dependent. When
  /// in doubt a code is left data-dependent — a missed structural code only
  /// lowers the tripwire's sensitivity, whereas a misclassified data-dependent
  /// code would false-positive the whole suite.
  private static func structural(_ fault: SQLError) -> Bool {
    switch fault {
    case .relation, .column, .ambiguous, .function, .named,
         .columns, .duplicate, .redefinition, .arity, .unsupported,
         .statement, .grouping, .distinct:
      true
    case .character, .unterminated, .unexpected, .incomplete, .trailing:
      true
    case .operand, .overflow, .argument, .divide, .magnitude, .recursion,
         .cardinality:
      false
    case let .state(code, _):
      (code.hasPrefix("42") && code != "42804") || code.hasPrefix("0A")
    }
  }

  /// Whether `routines` carries a routine the run invokes but the schema path
  /// only validates by signature — a host-registered native closure or a
  /// defined `CREATE FUNCTION` body, i.e. any routine beyond the standard
  /// prelude. Such a body may throw a `structural`-classed `SQLError`
  /// (`.function`, a `42883` / `42000` passthrough, …) for particular argument
  /// values at run time, while `columns(of:)` validates the routine's declared
  /// signature without invoking the body and rightly succeeds — an expected
  /// run/validate difference whose origin is the body, not a hole the schema
  /// derive owns. So the tripwire exempts a query run through such routines,
  /// composing as an extra gate beside the `bindings.isEmpty` and `structural`
  /// ones.
  ///
  /// The detection is keyed on the routine set rather than the call site: a
  /// per-call walk of the query for the routines it actually invokes would need
  /// the engine's internal expression AST, which this framework — importing
  /// only the public surface — cannot see. It over-skips only a query that
  /// carries a caller routine yet never calls it, a sound loss of sensitivity
  /// confined to those tests, never a false positive.
  ///
  /// The set is trusted (the tripwire fires) only when every routine it binds
  /// is the standard prelude's own shipped routine for that name — the routine
  /// value `Routines.standard` binds to the name, tested by construction
  /// identity (`Routine.same(as:)`), not by the name and not by the protection
  /// set. `Routines.standard` is a `static let` built once, so the `Routine` it
  /// vends for a name is a stable instance; a set derived from it keeps that
  /// instance for a name it leaves alone and substitutes a fresh one for a name
  /// it rebinds.
  ///
  /// Identity is the discriminator because neither cheaper proxy survives the
  /// merge path. The standard routines are themselves native closures, so a
  /// native-versus-defined `Routine` predicate could not tell them from a
  /// caller's and would exempt every standard-routine query. A name-set test
  /// misses a standard name rebound to a caller body. And protection is a set
  /// property the merge unions, so `Routines.standard.merging(custom)` keeps a
  /// replaced name's protection bit set while the binding under it is now the
  /// caller's — a protection test reads that set as standard-only and fires
  /// spuriously. Construction identity is unforgeable: every `Routine`
  /// initializer — the public native init, the dictionary literal,
  /// `registering(_:…)`, the replacing side of `merging(_:)` — mints a fresh
  /// token, and the only route to a routine's identity is that routine value
  /// itself.
  ///
  /// So a new name (absent from `standard`) and a standard name rebound to a
  /// caller body — through the dictionary-literal escape hatch or through
  /// `merging(_:)`, each a fresh identity — both read as non-standard and
  /// exempt the query, while a set that is exactly the standard routines,
  /// whatever its protection, reads as standard and stays subject to the
  /// tripwire.
  ///
  /// The detection is keyed on the routine set rather than the call site: a
  /// per-call walk of the query for the routines it actually invokes would need
  /// the engine's internal expression AST, which this framework — importing
  /// only the public surface — cannot see. It over-skips only a query that
  /// carries a caller routine yet never calls it, a sound loss of sensitivity
  /// confined to those tests, never a false positive.
  private static func native(_ routines: Routines) -> Bool {
    !routines.names.allSatisfy {
      guard let bound = routines[$0], let shipped = Routines.standard[$0]
      else { return false }
      return bound.same(as: shipped)
    }
  }

  /// Checks `sql` run against this catalog yields exactly `rows`, each row a
  /// list of Swift literals lifted into `Value`s.
  public borrowing func expect(_ sql: String,
                               yields rows: Array<Array<(any ValueConvertible)?>>,
                               routines: Routines = .standard,
                               bindings: Bindings = [:],
                               location: Testing.SourceLocation =
                                  #_sourceLocation)
      throws {
    let expected = rows.map { $0.map { $0?.value ?? .null } }
    let actual = try run(sql, routines: routines, bindings: bindings,
                         location: location)
    #expect(actual == expected, sourceLocation: location)
  }

  /// Checks `sql` run against this catalog yields no rows.
  public borrowing func empty(_ sql: String, routines: Routines = .standard,
                              bindings: Bindings = [:],
                              location: Testing.SourceLocation =
                                  #_sourceLocation)
      throws {
    let actual = try run(sql, routines: routines, bindings: bindings,
                         location: location)
    #expect(actual.isEmpty, sourceLocation: location)
  }

  /// Checks `sql` run against this catalog raises `error`.
  ///
  /// The run is eager rather than wrapped in `#expect(throws:)`'s closure — a
  /// borrowed `~Escapable` catalog cannot be captured by an escaping closure —
  /// so it catches the outcome and asserts on it, still reporting at the call
  /// site.
  public borrowing func expect(_ sql: String, fails error: SQLError,
      routines: Routines = .standard, bindings: Bindings = [:],
      location: Testing.SourceLocation = #_sourceLocation) {
    let raised: SQLError?
    do {
      _ = try run(sql, routines: routines, bindings: bindings,
                  location: location)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised == error, sourceLocation: location)
  }

  /// Checks two queries run against this catalog yield the same rows — the
  /// seek / scan (or hash / seek) equivalence idiom.
  public borrowing func expect(_ lhs: String, equals rhs: String,
                               routines: Routines = .standard,
                               bindings: Bindings = [:],
                               location: Testing.SourceLocation =
                                  #_sourceLocation)
      throws {
    let left = try run(lhs, routines: routines, bindings: bindings,
                       location: location)
    let right = try run(rhs, routines: routines, bindings: bindings,
                        location: location)
    #expect(left == right, sourceLocation: location)
  }
}
