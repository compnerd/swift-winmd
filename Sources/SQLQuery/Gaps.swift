// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// Engine-blocked LINQ surface — the operators with no node in today's engine
// AST to lower against. They are deliberately not offered: faking a lowering
// would build a query the engine cannot execute, so each waits on a real engine
// feature rather than a change to this module.
//
// Window functions — `PARTITION BY`, `OVER`, ranking (`ROW_NUMBER`, `RANK`, …):
//   the engine has no window node, so no LINQ operator maps until one is added.
//
// Write combinators — `Insert`/`Update`/`Delete`: the engine is read-only (only
//   `CREATE VIEW`/`CREATE FUNCTION` define; `run` rejects a write), so these
//   wait on the read-write storage roadmap's DML statements.
