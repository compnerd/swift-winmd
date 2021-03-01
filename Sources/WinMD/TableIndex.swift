/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

enum TableIndex {
  case string
  case guid
  case blob
  case simple(Table.Type)
  case coded(ObjectIdentifier)
}

extension TableIndex: Hashable {
  static func == (_ lhs: TableIndex, _ rhs: TableIndex) -> Bool {
    switch (lhs, rhs) {
    case (.string, .string):
      return true
    case (.guid, .guid):
      return true
    case (.blob, .blob):
      return true
    case let (.simple(LHSTable), .simple(RHSTable)) where LHSTable == RHSTable:
      return true
    case let (.coded(LHSSet), .coded(RHSSet)) where LHSSet == RHSSet:
      return true
    default: return false
    }
  }

  func hash(into hasher: inout Hasher) {
    switch self {
    case .string:
      hasher.combine(3)
    case .guid:
      hasher.combine(2)
    case .blob:
      hasher.combine(1)
    case let .simple(table):
      hasher.combine(ObjectIdentifier(table))
    case let .coded(index):
      index.hash(into: &hasher)
    }
  }
}
