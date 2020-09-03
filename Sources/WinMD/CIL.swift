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

internal struct Assembly {
  internal let envelope: PEFile
  internal let data: Data

  public var Header: IMAGE_COR20_HEADER {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_COR20_HEADER.self).baseAddress!.pointee
    }
  }

  public var Metadata: Result<Metadata, WinMDError> {
    let VA: DWORD = Header.MetaData.VirtualAddress

    var LA: DWORD = 0
    switch envelope.Sections {
    case .failure(let error):
      return .failure(error)
    case .success(let sections):
      let headers: [IMAGE_SECTION_HEADER] = sections.containing(rva: VA)
      guard headers.count == 1 else {
        return .failure(WinMDError.BadImageFormat)
      }
      LA = headers.first!.offset(from: VA)
    }

    let data: Data = envelope.data.suffix(from: numericCast(LA))

    let metadata = WinMD.Metadata(data: data)
    do {
      try metadata.validate()
    } catch(let error) {
      return .failure(error as! WinMDError)
    }
    return .success(metadata)
  }

  public init(from pe: PEFile) throws {
    var VA: DWORD = 0
    switch pe.Header32.OptionalHeader.Magic {
    case WORD(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE: IMAGE_NT_HEADERS32 = pe.Header32
      VA = PE.OptionalHeader.DataDirectory.14.VirtualAddress
    case WORD(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE: IMAGE_NT_HEADERS64 = pe.Header64
      VA = PE.OptionalHeader.DataDirectory.14.VirtualAddress
    default:
      throw WinMDError.BadImageFormat
    }

    var LA: DWORD = 0
    switch pe.Sections {
    case .failure(let error):
      throw error
    case .success(let sections):
      let headers: [IMAGE_SECTION_HEADER] = sections.containing(rva: VA)
      guard headers.count == 1 else {
        throw WinMDError.BadImageFormat
      }
      LA = headers.first!.offset(from: VA)
    }

    self.data = pe.data.suffix(from: numericCast(LA))
    self.envelope = pe
  }

  public func validate() throws {
    guard data.count > MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }

    guard Header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw WinMDError.BadImageFormat
    }
  }
}

private var CIL_METADATA_SIGNATURE: DWORD { 0x424a5342 }

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

/// Metadata
///     uint32_t Signature              ; +0
///     uint16_t MajorVersion           ; +4
///     uint16_t MinorVersion           ; +6
///     uint32_t Reserved               ; +8
///     uint32_t Length                 ; +12
///      uint8_t Version[]              ; +16
///     uint16_t Flags                  ; +16 + Length
///     uint16_t Streams                ; +18 + Length
///              StreamHeaders[Streams] ; +20 + Length
internal struct Metadata {
  internal let data: Data

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
    let buffer: [UInt8] = Array<UInt8>(unsafeUninitializedCapacity: length) {
      let begin: Data.Index = data.index(data.startIndex, offsetBy: 16)
      let end: Data.Index = data.index(begin, offsetBy: length)
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

extension Metadata {
  public func validate() throws {
    guard Signature == CIL_METADATA_SIGNATURE else {
      throw WinMDError.BadImageFormat
    }
  }
}

extension Metadata {
  internal enum Stream: String {
  case Tables = "#~"
  case Strings = "#Strings"
  case Blob = "#Blob"
  case GUID = "#GUID"
  case UserStrings = "#US"
  case PDB = "#Pdb"
  }
}

extension Metadata {
  public func stream(named name: Metadata.Stream) -> Data? {
    return stream(named: name.rawValue)
  }

  public func stream(named name: String) -> Data? {
    let headers = StreamHeaders.filter({ $0.Name == name })
    guard headers.count == 1, let header = headers.first else {
      return nil
    }

    let begin: Data.Index =
        data.index(data.startIndex, offsetBy: Int(header.Offset))
    let end: Data.Index = data.index(begin, offsetBy: Int(header.Size))
    return data[begin ..< end]
  }
}

extension Metadata {
  internal enum Table: Int {
  case Module = 0
  case TypeRef = 1
  case TypeDef = 2
  case Field = 4
  case MethodDef = 6
  case Param = 8
  case InterfaceImpl = 9
  case MemberRef = 10
  case Constant = 11
  case CustomAttribute = 12
  case FieldMarshal = 13
  case DeclSecurity = 14
  case ClassLayout = 15
  case FieldLayout = 16
  case StandAloneSig = 17
  case EventMap = 18
  case Event = 20
  case PropertyMap = 21
  case Property = 23
  case MethodSemantics = 24
  case MethodImpl = 25
  case ModuleRef = 26
  case TypeSpec = 27
  case ImplMap = 28
  case FieldRVA = 29
  case Assembly = 32
  case AssemblyProcessor = 33
  case AssemblyOS = 34
  case AssemblyRef = 35
  case AssemblyRefProcessor = 36
  case AssemblyRefOS = 37
  case File = 38
  case ExportedType = 39
  case ManifestResource = 40
  case NestedClass = 41
  case GenericParam = 42
  case GenericParamConstraint = 44
  }
}

extension Metadata.Table: CaseIterable {
}

/// MetaData Tables Stream
///     uint32_t Reserved           ; +0 [0]
///      uint8_t MajorVersion       ; +4
///      uint8_t MinorVersion       ; +5
///      uint8_t HeapOffsetSizes    ; +6
///      uint8_t Reserved           ; +7 [1]
///     uint64_t Valid              ; +8
///     uint64_t Sorted             ; +16
///     uint32_t Rows[]             ; +24
internal struct MetadataTablesStream {
  internal let data: Data

  public var MajorVersion: UInt8 {
    return data.read(offset: 4)
  }

  public var MinorVersion: UInt8 {
    return data.read(offset: 5)
  }

  public var HeapOffsetSizes: UInt8 {
    return data.read(offset: 6)
  }

  public var Valid: UInt64 {
    return data.read(offset: 8)
  }

  public var Sorted: UInt64 {
    return data.read(offset: 16)
  }

  public var Rows: [DWORD] {
    let tables: Int = Valid.nonzeroBitCount
    let nbytes: Int = tables * MemoryLayout<DWORD>.size
    let begin: Data.Index = data.index(data.startIndex, offsetBy: 24)
    let end: Data.Index = data.index(begin, offsetBy: nbytes)
    return Array<DWORD>(unsafeUninitializedCapacity: tables) {
      data.copyBytes(to: $0, from: begin ..< end)
      $1 = tables
    }
  }
}

extension MetadataTablesStream {
  public var tables: [Metadata.Table] {
    let valid:  UInt64 = Valid

    var tables: [Metadata.Table] = []
    tables.reserveCapacity(valid.nonzeroBitCount)

    for table in Metadata.Table.allCases {
      if valid & (1 << table.rawValue) == (1 << table.rawValue) {
        tables.append(table)
      }
    }

    return tables
  }

  public func rows(in table: Metadata.Table) throws -> DWORD {
    let index = table.rawValue

    guard Valid & (1 << index) == (1 << index) else {
      throw WinMDError.tableNotFound
    }
    return Rows[(Valid & ((1 << index) - 1)).nonzeroBitCount]
  }
}
