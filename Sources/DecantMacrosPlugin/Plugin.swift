// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler-plugin entry point — the host process the toolchain launches to
/// expand the `DecantMacros` derive declarations. swift-syntax is depended on
/// ONLY by this `.macro` target, so it is compile-time-only and never links
/// into a client.
@main
internal struct DecantMacrosPlugin: CompilerPlugin {
  internal let providingMacros: Array<any Macro.Type> = [
    SerializableMacro.self,
    DeserializableMacro.self,
    DecantNameMacro.self,
    DecantSkipMacro.self,
  ]
}
