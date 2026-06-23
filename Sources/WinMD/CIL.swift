// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import CPE

private var CIL_METADATA_SIGNATURE: UInt32 { 0x424a5342 }

/// An absolute byte region within the backing buffer.
internal struct Region {
  internal let offset: Int
  internal let size: Int
}

extension PEFile {
  internal func contents(_ directory: IMAGE_DATA_DIRECTORY)
      throws(WinMDError) -> Region {
    // Exactly one section must contain the directory's address.
    let rva = directory.VirtualAddress
    var match: IMAGE_SECTION_HEADER?
    for index in 0 ..< NumberOfSections {
      let header = section(at: index)
      let start = header.VirtualAddress
      guard rva >= start, rva < start + header.Misc.VirtualSize else {
        continue
      }
      guard match == nil else { throw .BadImageFormat }
      match = header
    }

    guard let match else { throw .BadImageFormat }
    let address = match.offset(from: rva)
    return Region(offset: Int(address), size: Int(directory.Size))
  }
}

/// A borrowed view over the CLI (COR20) contents of a PE image.
///
/// Used transiently during database parsing. It operates on the whole-buffer
/// span; `header` and `metadata` are absolute byte regions within the buffer.
internal struct Assembly: ~Escapable {
  internal let bytes: RawSpan
  private let header: Region
  private let metadata: Region

  internal var Header: IMAGE_COR20_HEADER {
    bytes.load(at: header.offset, as: IMAGE_COR20_HEADER.self)
  }

  internal var Metadata: MetadataRoot {
    @_lifetime(copy self)
    get { MetadataRoot(bytes, base: metadata.offset) }
  }

  @_lifetime(copy pe)
  internal init(from pe: PEFile) throws(WinMDError) {
    self.bytes = pe.bytes

    let directory = pe.DataDirectory.14

    // CLI Header
    self.header = try pe.contents(directory)

    let header =
        pe.bytes.load(at: self.header.offset, as: IMAGE_COR20_HEADER.self)

    guard header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw .BadImageFormat
    }

    // CLI Metadata
    self.metadata = try pe.contents(header.MetaData)

    guard Metadata.Signature == CIL_METADATA_SIGNATURE else {
      throw .BadImageFormat
    }
  }
}

/// Stream Header
///     uint32_t Offset     ; +0
///     uint32_t Size       ; +4
///      uint8_t Name[]     ; +8
internal struct StreamHeader: ~Escapable {
  internal let bytes: RawSpan
  /// The absolute byte offset of the header within the buffer.
  internal let base: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan, base: Int) {
    self.bytes = bytes
    self.base = base
  }

  internal var Offset: UInt32 {
    bytes.read(at: base + 0, as: UInt32.self)
  }

  internal var Size: UInt32 {
    bytes.read(at: base + 4, as: UInt32.self)
  }

  internal var Name: String {
    // The name is a null-terminated ASCII string beginning at offset 8.
    var end = base + 8
    while end < bytes.byteCount,
        bytes.read(at: end, as: UInt8.self) != 0 {
      end += 1
    }
    return String(decoding: bytes.extracting((base + 8) ..< end),
                  as: Unicode.ASCII.self)
  }
}

/// Metadata Root
///     uint32_t Signature              ; +0
///     uint16_t MajorVersion           ; +4
///     uint16_t MinorVersion           ; +6
///     uint32_t Reserved               ; +8
///     uint32_t Length                 ; +12
///      uint8_t Version[]              ; +16
///     uint16_t Flags                  ; +16 + Length
///     uint16_t Streams                ; +18 + Length
///              StreamHeaders[Streams] ; +20 + Length
internal struct MetadataRoot: ~Escapable {
  internal let bytes: RawSpan
  /// The absolute byte offset of the metadata root within the buffer.
  internal let base: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan, base: Int) {
    self.bytes = bytes
    self.base = base
  }

  internal var Signature: UInt32 {
    bytes.read(at: base + 0, as: UInt32.self)
  }

  internal var MajorVersion: UInt16 {
    bytes.read(at: base + 4, as: UInt16.self)
  }

  internal var MinorVersion: UInt16 {
    bytes.read(at: base + 6, as: UInt16.self)
  }

  internal var Reserved: UInt32 {
    bytes.read(at: base + 8, as: UInt32.self)
  }

  internal var Length: UInt32 {
    bytes.read(at: base + 12, as: UInt32.self)
  }

  internal var Version: String {
    let begin = base + 16
    let end = begin + numericCast(Length)
    return String(decoding: bytes.extracting(begin ..< end),
                  as: Unicode.ASCII.self)
  }

  internal var Streams: UInt16 {
    bytes.read(at: base + 18 + Int(Length), as: UInt16.self)
  }
}

extension MetadataRoot {
  private func padded(_ value: Int, to: Int) -> Int {
    (value + to - 1) / to * to
  }

  internal func stream(named name: Metadata.Stream) -> Region? {
    stream(named: name.rawValue)
  }

  internal func stream(named name: String) -> Region? {
    var offset = base + 20 + Int(Length)
    for _ in 0 ..< Int(Streams) {
      let header = StreamHeader(bytes, base: offset)
      let label = header.Name
      if label == name {
        return Region(offset: base + Int(header.Offset),
                      size: Int(header.Size))
      }
      // name + NUL, padded to 4
      offset = offset + 8 + padded(label.count + 1, to: 4)
    }
    return nil
  }
}

public enum Metadata {
}

extension Metadata {
  public enum Stream: String {
    case Tables = "#~"
    case Strings = "#Strings"
    case Blob = "#Blob"
    case GUID = "#GUID"
    case UserStrings = "#US"
  }
}
