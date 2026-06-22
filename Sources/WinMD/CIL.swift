// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import CPE

private var CIL_METADATA_SIGNATURE: UInt32 { 0x424a5342 }

extension PEFile {
  internal func contents(_ directory: IMAGE_DATA_DIRECTORY)
      throws(WinMDError) -> ArraySlice<UInt8> {
    let sections = Sections.containing(rva: directory.VirtualAddress)
    guard sections.count == 1 else { throw .BadImageFormat }

    let LogicalAddress = sections.first!.offset(from: directory.VirtualAddress)

    let begin = ArraySlice<UInt8>.Index(LogicalAddress)
    let end = data.index(begin, offsetBy: numericCast(directory.Size))

    return data[begin ..< end]
  }
}

public struct Assembly {
  private let header: ArraySlice<UInt8>
  private let metadata: ArraySlice<UInt8>

  public var Header: IMAGE_COR20_HEADER {
    header.withUnsafeBytes {
      $0.load(as: IMAGE_COR20_HEADER.self)
    }
  }

  public var Metadata: MetadataRoot {
    MetadataRoot(data: metadata)
  }

  public init(from pe: PEFile) throws(WinMDError) {
    let COMDescriptor = pe.DataDirectory.14

    // CLI Header
    self.header = try pe.contents(COMDescriptor)

    let Header = header.withUnsafeBytes {
      $0.load(as: IMAGE_COR20_HEADER.self)
    }

    guard Header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw .BadImageFormat
    }

    // CLI Metadata
    self.metadata = try pe.contents(Header.MetaData)

    guard Metadata.Signature == CIL_METADATA_SIGNATURE else {
      throw .BadImageFormat
    }
  }
}

/// Stream Header
///     uint32_t Offset     ; +0
///     uint32_t Size       ; +4
///      uint8_t Name[]     ; +8
public struct StreamHeader {
  internal let data: ArraySlice<UInt8>

  public var Offset: UInt32 {
    data[0, UInt32.self]
  }

  public var Size: UInt32 {
    data[4, UInt32.self]
  }

  public var Name: String {
    let begin = data.index(data.startIndex, offsetBy: 8)
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
    "Offset: \(String(Offset, radix: 16)), Size: \(String(Size, radix: 16)), Name: \(Name)"
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
public struct MetadataRoot {
  private let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public var Signature: UInt32 {
    data[0, UInt32.self]
  }

  public var MajorVersion: UInt16 {
    data[4, UInt16.self]
  }

  public var MinorVersion: UInt16 {
    data[6, UInt16.self]
  }

  public var Reserved: UInt32 {
    data[8, UInt32.self]
  }

  public var Length: UInt32 {
    data[12, UInt32.self]
  }

  public var Version: String {
    let begin = data.index(data.startIndex, offsetBy: 16)
    let end = data.index(begin, offsetBy: numericCast(Length))
    return String(bytes: data[begin ..< end], encoding: .ascii)!
  }

  public var Streams: UInt16 {
    data[18 + Int(Length), UInt16.self]
  }

  public var StreamHeaders: Array<StreamHeader> {
    let count = Int(Streams)

    var headers = Array<StreamHeader>()
    headers.reserveCapacity(count)

    func align(_ value: Int, to: Int) -> Int {
      value + (to - value % to)
    }

    var offset = 20 + Int(Length)
    (0 ..< count).forEach { _ in
      let begin = data.index(data.startIndex, offsetBy: offset)

      // FIXME(compnerd) truncate to the actual length of the header
      let header = StreamHeader(data: data[begin...])
      headers.append(header)

      offset = offset + 8 + align(header.Name.count, to: 4)
    }

    return headers
  }
}

extension MetadataRoot {
  public func stream(named name: Metadata.Stream) -> ArraySlice<UInt8>? {
    stream(named: name.rawValue)
  }

  public func stream(named name: String) -> ArraySlice<UInt8>? {
    let headers = StreamHeaders.filter { $0.Name == name }
    guard headers.count == 1, let header = headers.first else {
      return nil
    }

    let begin = data.index(data.startIndex, offsetBy: Int(header.Offset))
    let end = data.index(begin, offsetBy: Int(header.Size))
    return data[begin ..< end]
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
