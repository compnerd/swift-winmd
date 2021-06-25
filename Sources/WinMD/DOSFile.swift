// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_implementationOnly
import CPE

internal struct DOSFile {
  internal let data: [UInt8]

  public init(from data: [UInt8]) throws {
    // NOTE: We initialize the properties before validating the input to avoid
    // duplicating the logic to extract the header or converting the validation
    // into a static method.
    self.data = data

    // Must have enough data to even contain a DOS stub.
    guard self.data.count >= MemoryLayout<IMAGE_DOS_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }

    // Bad signature? Not a DOS file.
    guard self.Header.e_magic == IMAGE_DOS_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }

    // The LFA of the PE signature (if there is one) must be within the file's
    // bounds.
    guard self.Header.e_lfanew < self.data.count else {
      throw WinMDError.BadImageFormat
    }
  }

  /// The raw MS-DOS stub image header.
  public var Header: IMAGE_DOS_HEADER {
    return self.data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_DOS_HEADER.self)[0]
    }
  }

  /// The complete contents of the file excluding the MS-DOS stub. Returns a
  /// slice to help avoid excess copying.  This unwraps the MS-DOS stub
  /// envelope on a PE/COFF file.
  public var NewExecutable: ArraySlice<UInt8> {
    return self.data[numericCast(self.Header.e_lfanew)...]
  }
}
