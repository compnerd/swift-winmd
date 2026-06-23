// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A table field.
///
/// Accessible fields have a name which the user can use to reference the
/// field, and a type which indicates how to read the value of the field.
public struct Field: Sendable {
  public let name: StaticString
  public let type: ColumnType
}
