// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Identifies the well-known heap.
public enum Heap {
  /// The blob heap.
  case blob

  /// The GUID heap.
  case guid

  /// The string heap.
  case string
}

/// A foreign-key index.
public enum Index {
  /// Index into a well known heap.
  case heap(Heap)

  /// A simple index to a table.
  case simple(Table.Type)

  /// A coded-index.
  case coded(CodedIndex.Type)
}

extension Index: Equatable {
  /// See `Equatable`.
  public static func == (lhs: Index, rhs: Index) -> Bool {
    switch (lhs, rhs) {
    case let (.heap(lhs), .heap(rhs)):
      return lhs == rhs
    case let (.simple(lhs), .simple(rhs)):
      return lhs == rhs
    case let (.coded(lhs), .coded(rhs)):
      return lhs == rhs
    default:
      return false
    }
  }
}

extension Index: Hashable {
  /// See `Hashable`.
  public func hash(into hasher: inout Hasher) {
    switch self {
    case let .heap(heap):
      hasher.combine(heap)
    case let .simple(table):
      // FIXME(compnerd) is this correct?
      hasher.combine(ObjectIdentifier(table))
    case let .coded(coded):
      // FIXME(compnerd) is this correct?
      hasher.combine(ObjectIdentifier(coded))
    }
  }
}
