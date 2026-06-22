// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import CPE

public struct DOSFile {
  internal let data: Array<UInt8>

  public init(from data: Array<UInt8>) throws(WinMDError) {
    // NOTE: We initialize the properties before validating the input to avoid
    // duplicating the logic to extract the header or converting the validation
    // into a static method.
    self.data = data

    // Must have enough data to even contain a DOS stub.
    guard data.count >= MemoryLayout<IMAGE_DOS_HEADER>.size else {
      throw .BadImageFormat
    }

    // Bad signature? Not a DOS file.
    guard Header.e_magic == IMAGE_DOS_SIGNATURE else {
      throw .BadImageFormat
    }

    // The LFA of the PE signature (if there is one) must be within the file's
    // bounds.
    guard Header.e_lfanew < data.count else {
      throw .BadImageFormat
    }
  }

  /// The raw MS-DOS stub image header.
  public var Header: IMAGE_DOS_HEADER {
    data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_DOS_HEADER.self)[0]
    }
  }

  /// The complete contents of the file excluding the MS-DOS stub. Returns a
  /// slice to help avoid excess copying. This unwraps the MS-DOS stub
  /// envelope on a PE/COFF file.
  public var NewExecutable: ArraySlice<UInt8> {
    data[numericCast(Header.e_lfanew)...]
  }
}
