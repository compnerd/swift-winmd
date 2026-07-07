// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// The umbrella module: one `import SQL` brings the pure engine (`SQLEngine`)
// and the ISO standard-library prelude with its import-activated defaulting
// (`SQLStandard`). This is the conformance-by-default surface — a consumer that
// wants the built-ins available without threading `Routines.standard` imports
// `SQL`; a consumer that wants the pure engine alone imports `SQLEngine`.

@_exported import SQLEngine
@_exported import SQLStandard
