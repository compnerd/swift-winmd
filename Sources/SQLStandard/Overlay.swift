// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The prelude-defaulting overlay: `import SQLStandard` re-defaults the standard
// prelude on the engine's pure entry points. The engine takes routines
// explicitly and seeds no built-ins; these overloads supply `Routines.standard`
// so a call that names no routines resolves the ISO built-ins. `import
// SQLEngine` alone sees only the pure entry points (routines passed
// explicitly, no prelude); adding this module — or the umbrella `SQL` —
// restores the conformance-by-default a single import gives.

extension Catalog where Self: ~Escapable {
  /// Runs `query` against this catalog with the standard prelude in scope,
  /// resolving a built-in (`UPPER`, `BITAND`, …) without the caller naming it.
  /// The pure engine `run(_:_:bindings:)` takes routines explicitly; this
  /// overload defaults them to `Routines.standard`.
  public borrowing func run(_ query: Query, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    try run(query, .standard, bindings: bindings)
  }

  /// Runs `statement` against this catalog with the standard prelude in scope —
  /// the prelude-defaulting counterpart of the pure engine overload.
  public borrowing func run(_ statement: Statement, bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    try run(statement, .standard, bindings: bindings)
  }

  /// The result columns `query` would yield, typed with the standard prelude in
  /// scope so a projected built-in reports its declared type. The pure engine
  /// `columns(of:routines:validate:)` requires routines; this defaults them.
  public borrowing func columns(of query: Query, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    try columns(of: query, routines: .standard, validate: validate)
  }

  /// The result columns `statement` would yield, typed with the standard
  /// prelude in scope — the prelude-defaulting counterpart of the pure
  /// overload.
  public borrowing func columns(of statement: Statement, validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    try columns(of: statement, routines: .standard, validate: validate)
  }
}

extension Routines {
  /// A copy of these routines with the DEFINED `function` bound to `name`, its
  /// body EARLY-BINDING against the standard prelude overlaid with these
  /// routines — the prelude-defaulting counterpart of the engine's
  /// `registering(_:_:capturing:)`, so `lowbit(n) AS BITAND(n, 1)` resolves the
  /// built-in at registration exactly as a query would. Registering a protected
  /// standard name still faults SQLSTATE `42723`.
  public func registering(_ name: String, _ function: Function)
      throws(SQLError) -> Routines {
    try registering(name, function, capturing: .standard)
  }
}
