/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

@_implementationOnly
import CPE

private var CIL_METADATA_SIGNATURE: UInt32 { 0x424a5342 }

internal struct Assembly {
  private let header: Data
  private let metadata: Data

  public var Header: IMAGE_COR20_HEADER {
    header.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_COR20_HEADER.self).baseAddress!.pointee
    }
  }

  public var Metadata: MetadataRoot {
    MetadataRoot(data: metadata)
  }

  public init(from pe: PEFile) throws {
    func data(VA: UInt32, Size: UInt32) throws -> Data {
      let sections = pe.Sections.containing(rva: VA)
      guard sections.count == 1, let LA = sections.first?.offset(from: VA) else {
        throw WinMDError.BadImageFormat
      }

      let begin: Data.Index = Data.Index(LA)
      let end: Data.Index = pe.data.index(begin, offsetBy: Int(Size))
      return Data(pe.data[begin ..< end])
    }

    // CLI Header
    let COMDescriptor: IMAGE_DATA_DIRECTORY = pe.DataDirectory.14
    self.header =
        try data(VA: COMDescriptor.VirtualAddress, Size: COMDescriptor.Size)

    let Header = header.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_COR20_HEADER.self).baseAddress!.pointee
    }

    // CLI Metadata
    self.metadata =
        try data(VA: Header.MetaData.VirtualAddress, Size: Header.MetaData.Size)
  }

  public func validate() throws {
    guard Header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }
    guard Metadata.Signature == CIL_METADATA_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
  }
}

/// Stream Header
///     uint32_t Offset     ; +0
///     uint32_t Size       ; +4
///      uint8_t Name[]     ; +8
internal struct StreamHeader {
  internal let data: Data

  public var Offset: UInt32 {
    return data.read(offset: 0)
  }

  public var Size: UInt32 {
    return data.read(offset: 4)
  }

  public var Name: String {
    let begin: Data.Index = data.index(data.startIndex, offsetBy: 8)
    return data[begin...].withUnsafeBytes {
      if let name =
          $0.baseAddress?.assumingMemoryBound(to: Unicode.ASCII.CodeUnit.self) {
        return String(decodingCString: name, as: Unicode.ASCII.self)
      }
      return ""
    }
  }
}

extension StreamHeader: CustomDebugStringConvertible {
  public var debugDescription: String {
    return "Offset: \(String(Offset, radix: 16)), Size: \(String(Size, radix: 16)), Name: \(Name)"
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
internal struct MetadataRoot {
  private let data: Data

  public init(data: Data) {
    self.data = data
  }

  public var Signature: UInt32 {
    return data.read(offset: 0)
  }

  public var MajorVersion: UInt16 {
    return data.read(offset: 4)
  }

  public var MinorVersion: UInt16 {
    return data.read(offset: 6)
  }

  public var Reserved: UInt32 {
    return data.read(offset: 8)
  }

  public var Length: UInt32 {
    return data.read(offset: 12)
  }

  public var Version: String {
    let length: Int = Int(Length)
    let begin: Data.Index = data.index(data.startIndex, offsetBy: 16)
    let end: Data.Index = data.index(begin, offsetBy: length)
    let buffer: [UInt8] = Array<UInt8>(unsafeUninitializedCapacity: length) {
      data.copyBytes(to: $0, from: begin ..< end)
      $1 = length
    }
    return String(decodingCString: buffer, as: Unicode.ASCII.self)
  }

  public var Streams: UInt16 {
    return data.read(offset: 18 + Int(Length))
  }

  public var StreamHeaders: [StreamHeader] {
    let count: Int = Int(Streams)

    var headers: [StreamHeader] = []
    headers.reserveCapacity(count)

    var offset: Int = 20 + Int(Length)
    for _ in 0 ..< count {
      let begin: Data.Index = data.index(data.startIndex, offsetBy: offset)

      // FIXME(compnerd) truncate to the actual length of the header
      let header: StreamHeader = StreamHeader(data: data[begin...])
      headers.append(header)

      func align(_ value: Int, to: Int) -> Int {
        return value + (to - value % to)
      }

      offset = offset + 8 + align(header.Name.count, to: 4)
    }

    return headers
  }
}

extension MetadataRoot {
  public func stream(named name: Metadata.Stream) -> Data? {
    return stream(named: name.rawValue)
  }

  public func stream(named name: String) -> Data? {
    let headers = StreamHeaders.filter { $0.Name == name }
    guard headers.count == 1, let header = headers.first else {
      return nil
    }

    let begin: Data.Index =
        data.index(data.startIndex, offsetBy: Int(header.Offset))
    let end: Data.Index = data.index(begin, offsetBy: Int(header.Size))
    return data[begin ..< end]
  }
}

internal enum Metadata {
}

extension Metadata {
  internal enum Stream: String {
    case Tables = "#~"
    case Strings = "#Strings"
    case Blob = "#Blob"
    case GUID = "#GUID"
    case UserStrings = "#US"
  }
}
