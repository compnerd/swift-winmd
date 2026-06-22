// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import CPE

/// A borrowed view over a PE/COFF image.
///
/// Used transiently during database parsing. It operates on the whole-buffer
/// span; `base` is the absolute byte offset, within the buffer, of the PE
/// image (i.e. just past the MS-DOS stub).
internal struct PEFile: ~Escapable {
  internal let bytes: RawSpan
  internal let base: Int

  internal var Header32: IMAGE_NT_HEADERS32 {
    bytes.load(at: base, as: IMAGE_NT_HEADERS32.self)
  }

  internal var Header64: IMAGE_NT_HEADERS64 {
    bytes.load(at: base, as: IMAGE_NT_HEADERS64.self)
  }

  internal var DataDirectory: (IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY, IMAGE_DATA_DIRECTORY) {
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      Header32.OptionalHeader.DataDirectory
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      Header64.OptionalHeader.DataDirectory
    default: fatalError("BAD_IMAGE_FORMAT")
    }
  }

  internal var Sections: Array<IMAGE_SECTION_HEADER> {
    switch Header32.OptionalHeader.Magic {
    case UInt16(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE = Header32
      let NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      let Offset = base + MemoryLayout.size(ofValue: PE)

      return (0 ..< NumberOfSections).map {
        bytes.load(at: Offset + $0 * MemoryLayout<IMAGE_SECTION_HEADER>.size,
                   as: IMAGE_SECTION_HEADER.self)
      }
    case UInt16(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE = Header64
      let NumberOfSections = Int(PE.FileHeader.NumberOfSections)
      let Offset = base + MemoryLayout.size(ofValue: PE)

      return (0 ..< NumberOfSections).map {
        bytes.load(at: Offset + $0 * MemoryLayout<IMAGE_SECTION_HEADER>.size,
                   as: IMAGE_SECTION_HEADER.self)
      }
    default: fatalError("BAD_IMAGE_FORMAT")
    }
  }

  @_lifetime(copy dos)
  internal init(from dos: DOSFile) throws(WinMDError) {
    self.bytes = dos.bytes
    self.base = dos.NewExecutable

    guard bytes.byteCount - base > MemoryLayout<IMAGE_NT_HEADERS32>.size else {
      throw .BadImageFormat
    }

    guard Header32.Signature == IMAGE_NT_SIGNATURE else {
      throw .BadImageFormat
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
