// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// DQL-BLOCKED SURFACE — the LINQ operators that do NOT lower against today's
// engine AST. They are DELIBERATELY not offered: the engine has no node to
// lower them to, so faking one would build a query it cannot execute. Each
// waits on a real engine feature, NOT a change to this module.
//
// TODO(DQL): window functions — `PARTITION BY`, `OVER`, ranking (ROW_NUMBER,
//   RANK, …). No window node exists in the engine AST; blocked until one is
//   added. No LINQ operator maps today.
//
// TODO(RW): write combinators — `Insert`/`Update`/`Delete`. The engine is
//   READ-ONLY (only `CREATE VIEW`/`CREATE FUNCTION` define; `run` rejects
//   them). Blocked on the read-write storage roadmap's DML statements.
//
// NOTE: `first`/`single`/`any` (no-arg) are NOT blocked and need no engine
//   feature — they are `FETCH FIRST 1 ROW ONLY` (`.limit(1)`) plus a
//   client-side reduce over the returned rows. They ARE now provided as thin
//   terminal wrappers over `.limit(_:)` + `run(against:…)` on `QueryBuilder`
//   (LINQ `First`/`Single`/`Any`, in `Run.swift`), not left for the caller to
//   compose.
