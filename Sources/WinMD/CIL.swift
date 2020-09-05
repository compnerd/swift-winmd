/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **/

import WinSDK
import Foundation

private var CIL_METADATA_SIGNATURE: DWORD { 0x424a5342 }

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
    func data(VA: DWORD, Size: DWORD) throws -> Data {
      let sections = pe.Sections.containing(rva: VA)
      guard sections.count == 1, let LA = sections.first?.offset(from: VA) else {
        throw WinMDError.BadImageFormat
      }

      let begin: Data.Index = Data.Index(LA)
      let end: Data.Index = pe.data.index(begin, offsetBy: Int(Size))
      return pe.data[begin ..< end]
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
      String(decodingCString: $0.baseAddress!.assumingMemoryBound(to: Unicode.ASCII.CodeUnit.self),
             as: Unicode.ASCII.self)
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
