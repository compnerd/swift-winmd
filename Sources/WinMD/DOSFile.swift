/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

@_implementationOnly
import CPE

internal struct DOSFile {
  internal let data: Data

  public var Header: IMAGE_DOS_HEADER {
    return data.withUnsafeBytes {
      return $0.bindMemory(to: IMAGE_DOS_HEADER.self).baseAddress!.pointee
    }
  }

  public func validate() throws {
    guard data.count > MemoryLayout<IMAGE_DOS_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }

    guard Header.e_magic == IMAGE_DOS_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
  }
}
