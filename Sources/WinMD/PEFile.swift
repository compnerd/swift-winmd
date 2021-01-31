/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import CPE
import Foundation

internal struct PEFile {
  internal let data: ArraySlice<UInt8>

  public var Header32: IMAGE_NT_HEADERS32 { self.data[unsafelyCasting: 0] }
  public var Header64: IMAGE_NT_HEADERS64 { self.data[unsafelyCasting: 0] }

  public var DataDirectory: (IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY) {
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      return Header32.OptionalHeader.DataDirectory
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      return Header64.OptionalHeader.DataDirectory
    default: fatalError("BAD_IMAGE_FORMAT")
    }
  }

  public var Sections: [IMAGE_SECTION_HEADER] {
    let NumberOfSections: Int
    let Offset: Int
    
    switch self.Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE: IMAGE_NT_HEADERS32 = self.Header32
      NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      Offset = MemoryLayout.size(ofValue: PE)
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE: IMAGE_NT_HEADERS64 = self.Header64
      NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      Offset = MemoryLayout.size(ofValue: PE)
    default: fatalError("BAD_IMAGE_FORMAT")
    }
    
    return (0..<NumberOfSections).map { self.data[self.data.index(self.data.startIndex, offsetBy: Offset)...][unsafelyCasting: $0] }
  }

  public init(from dos: DOSFile) throws {
    self.data = dos.NewExecutable
    
    guard self.data.count > MemoryLayout<IMAGE_NT_HEADERS32>.size else {
      throw WinMDError.BadImageFormat
    }
    guard self.Header32.Signature == IMAGE_NT_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
  }
}

extension Array where Array.Element == IMAGE_SECTION_HEADER {
  internal func containing(rva: UInt32) -> [IMAGE_SECTION_HEADER] {
    return self.filter { ($0.VirtualAddress..<($0.VirtualAddress + $0.Misc.VirtualSize)).contains(rva) }
  }
}

extension IMAGE_SECTION_HEADER {
  internal func offset(from rva: UInt32) -> UInt32 {
    return rva - self.VirtualAddress + self.PointerToRawData
  }
}
