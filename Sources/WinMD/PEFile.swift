// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_implementationOnly
import CPE

internal struct PEFile {
  internal let data: ArraySlice<UInt8>

  public var Header32: IMAGE_NT_HEADERS32 {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS32.self)[0]
    }
  }

  public var Header64: IMAGE_NT_HEADERS64 {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS64.self)[0]
    }
  }

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
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE: IMAGE_NT_HEADERS32 = Header32
      let NumberOfSections: Int = Int(PE.FileHeader.NumberOfSections)
      let Offset: Int = MemoryLayout.size(ofValue: PE)

      return Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes: Int = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin: ArraySlice<UInt8>.Index = data.index(data.startIndex, offsetBy: Offset)
        let end: ArraySlice<UInt8>.Index = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      }
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE: IMAGE_NT_HEADERS64 = Header64
      let NumberOfSections: Int = Int(PE.FileHeader.NumberOfSections)
      let Offset: Int = MemoryLayout.size(ofValue: PE)

      return Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes: Int = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin: ArraySlice<UInt8>.Index = data.index(data.startIndex, offsetBy: Offset)
        let end: ArraySlice<UInt8>.Index = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      }
    default: fatalError("BAD_IMAGE_FORMAT")
    }
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
    return self.filter {
      rva >= $0.VirtualAddress && rva < $0.VirtualAddress + $0.Misc.VirtualSize
    }
  }
}

extension IMAGE_SECTION_HEADER {
  internal func offset(from rva: UInt32) -> UInt32 {
    return rva - self.VirtualAddress + self.PointerToRawData
  }
}
