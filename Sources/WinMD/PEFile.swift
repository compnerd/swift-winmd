// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import CPE

public struct PEFile {
  internal let data: ArraySlice<UInt8>

  public var Header32: IMAGE_NT_HEADERS32 {
    data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS32.self)[0]
    }
  }

  public var Header64: IMAGE_NT_HEADERS64 {
    data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS64.self)[0]
    }
  }

  public var DataDirectory: (IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY) {
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      Header32.OptionalHeader.DataDirectory
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      Header64.OptionalHeader.DataDirectory
    default: fatalError("BAD_IMAGE_FORMAT")
    }
  }

  public var Sections: Array<IMAGE_SECTION_HEADER> {
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE = Header32
      let NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      let Offset = MemoryLayout.size(ofValue: PE)

      return Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin = data.index(data.startIndex, offsetBy: Offset)
        let end = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      }
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE = Header64
      let NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      let Offset = MemoryLayout.size(ofValue: PE)

      return Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin = data.index(data.startIndex, offsetBy: Offset)
        let end = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      }
    default: fatalError("BAD_IMAGE_FORMAT")
    }
  }

  public init(from dos: DOSFile) throws {
    self.data = dos.NewExecutable

    guard data.count > MemoryLayout<IMAGE_NT_HEADERS32>.size else {
      throw WinMDError.BadImageFormat
    }

    guard Header32.Signature == IMAGE_NT_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
  }
}

extension Array where Array.Element == IMAGE_SECTION_HEADER {
  internal func containing(rva: UInt32) -> Array<IMAGE_SECTION_HEADER> {
    filter {
      rva >= $0.VirtualAddress && rva < $0.VirtualAddress + $0.Misc.VirtualSize
    }
  }
}

extension IMAGE_SECTION_HEADER {
  internal func offset(from rva: UInt32) -> UInt32 {
    rva - VirtualAddress + PointerToRawData
  }
}
