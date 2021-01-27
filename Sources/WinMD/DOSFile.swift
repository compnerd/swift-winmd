/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import CPE
import Foundation

internal struct DOSFile {
  internal let data: [UInt8]
  
  /// - Note: It's actually rather bad form to initialize the properties _before_ validating the input values, but in
  ///   this case it avoids either duplicating the "get the header" logic or making the validation logic an awkward ugly
  ///   static method. Since the underlying array buffer won't be copied by the assignment, it's fine.
  public init(from data: [UInt8]) throws {
    self.data = data
    
    // Must have enough data to even contain a DOS stub.
    guard self.data.count >= MemoryLayout<IMAGE_DOS_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }
    
    // Bad signature? Not a DOS file.
    guard self.Header.e_magic == IMAGE_DOS_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
    
    // The LFA of the PE signature (if there is one) must be within the file's bounds.
    guard self.Header.e_lfanew < self.data.count else {
      throw WinMDError.BadImageFormat
    }
  }

  /// The raw MS-DOS stub image header.
  public var Header: IMAGE_DOS_HEADER {
    return self.data.withUnsafeBufferPointer { $0.withMemoryRebound(to: IMAGE_DOS_HEADER.self) { $0.first! } }
  }
  
  /// The complete content of the file, minus the leading MS-DOS stub. Returns a slice to help avoid excess copying.
  public var contentsWithoutStub: ArraySlice<UInt8> {
    return self.data[numericCast(self.Header.e_lfanew)...]
  }
}
