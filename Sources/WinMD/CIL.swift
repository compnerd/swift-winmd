/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import CPE
import Foundation

private var CIL_METADATA_SIGNATURE: UInt32 { 0x424a5342 }

extension PEFile {
  fileprivate func DataOfSection(containing directory: IMAGE_DATA_DIRECTORY) throws -> ArraySlice<UInt8>? {
    let containingSections = self.Sections.containing(rva: directory.VirtualAddress)
    
    guard (0...1).contains(containingSections.count) else {
      throw WinMDError.BadImageFormat
    }
    guard let LogicalAddress = containingSections.first?.offset(from: directory.VirtualAddress) else {
      return nil
    }
    
    let enterIndex = self.data.index(self.data.startIndex, offsetBy: numericCast(LogicalAddress))
    let exitIndex = self.data.index(enterIndex, offsetBy: numericCast(directory.Size))
    
    return self.data[enterIndex..<exitIndex]
  }
}

internal struct Assembly {
  private let header: ArraySlice<UInt8>
  private let metadata: ArraySlice<UInt8>

  public let Header: IMAGE_COR20_HEADER
  public let Metadata: MetadataRoot

  public init(from pe: PEFile) throws {
    // In the case of this data, we are able to validate it before performing initialization.
    guard
      // COM descriptor/CLI Header
      let header = try pe.DataOfSection(containing: pe.DataDirectory.14),
      let Header = Optional.some(header[offset: header.startIndex, unsafelyCastTo: IMAGE_COR20_HEADER.self]),
      Header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size,
      
      // CLI Metadata
      let metadata = try pe.DataOfSection(containing: Header.MetaData),
      let Metadata = Optional.some(try MetadataRoot(data: metadata)),
      Metadata.Signature == CIL_METADATA_SIGNATURE
    else {
      throw WinMDError.BadImageFormat
    }
    
    self.header = header
    self.Header = Header
    self.metadata = metadata
    self.Metadata = Metadata
  }
}

/// Stream Header
///     uint32_t Offset     ; +0
///     uint32_t Size       ; +4
///      uint8_t Name[]     ; +8
///      uint8_t 0[]        ; +8 + Align(Name[]:Count, 4)
internal struct StreamHeader {
  internal let data: ArraySlice<UInt8>
  
  /// `MetadataRoot` uses this to make tracking the "next header offset" value easier.
  fileprivate static func sequenceParse(from data: ArraySlice<UInt8>, offset: inout Int) throws -> Self {
    let parsedHeader = try self.init(data: data[data.index(data.startIndex, offsetBy: offset)...])
    offset += parsedHeader.data.count
    return parsedHeader
  }
  
  internal init(data: ArraySlice<UInt8>) throws {
    // Start at the offset of `Name[]`.
    let nameIndex = data.index(data.startIndex, offsetBy: 8)
    
    guard
      // Find the next NUL byte. This can not be part of the name string, as names are pure ASCII.
      let nulIndex = data[nameIndex...].firstIndex(of: 0),

      // Find the next index at or after the NUL byte which is on a 4-byte alignment boundary. Insufficient bytes
      // remaining to reach the next word boundary is a parse error.
      let wordBoundaryIndex = data.index(nulIndex,
        offsetBy: (4 - data.distance(from: data.startIndex, to: nulIndex) % 4),
        limitedBy: data.index(before: data.endIndex)
      ),

      // Verify that any alignment bytes beyond the first NUL are also NUL.
      // TODO: Does the format of a StreamHeader actually promise this? Doesn't seem like it. Disabled for now.
      //data[nulIndex...wordBoundaryIndex].allSatisfy({ $0 == 0 }),
      
      // Parse the name as ASCII with a validating parse.
      let Name = String.init(bytes: data[nameIndex...nulIndex], encoding: .ascii)
    else {
      throw WinMDError.BadImageFormat
    }

    // Save the slice holding the data for this one header only.
    self.data = data[data.startIndex...wordBoundaryIndex]
    
    // Save the parsed name string so we don't end up parsing it over and over.
    self.Name = Name
  }
  
  public var Offset: UInt32 { self.data[offset: self.data.startIndex] }
  public var Size: UInt32 { self.data[offset: self.data.index(self.data.startIndex, offsetBy: 4)] }
  public let Name: String
}

extension StreamHeader: CustomDebugStringConvertible {
  public var debugDescription: String {
    return "Offset: \(String(self.Offset, radix: 16)), Size: \(String(self.Size, radix: 16)), Name: \(self.Name)"
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
  private let data: ArraySlice<UInt8>

  /// The validation of the data handled by this structure is a bit more intricate than most, and is
  /// quite entangled with the initialization steps. Additionally, some of the fields are relatively
  /// expensive to compute, so they are "cached" as stored properties instead of being recomputed on
  /// each access. To avoid code duplication, additional fields needed for those computations are also
  /// cached in the same fashion. The caching only costs a few extra bytes per instance.
  public init(data: ArraySlice<UInt8>) throws {
    // Enforce that version strings must contain only valid ASCII codepoints.
    let versionLength = data[offset: data.index(data.startIndex, offsetBy: 12), unsafelyCastTo: UInt32.self]
    guard let version = String(bytes: data[
      data.index(data.startIndex, offsetBy: 16)..<data.index(data.startIndex, offsetBy: 16 + numericCast(versionLength))
    ], encoding: .ascii) else {
      throw WinMDError.BadImageFormat
    }
    let streamCount = data[offset: data.index(data.startIndex, offsetBy: 18 + numericCast(versionLength)), unsafelyCastTo: UInt16.self]
    var offset = 20 + numericCast(versionLength)
    let streamHeaders = try (0 ..< streamCount).map { _ in try StreamHeader.sequenceParse(from: data, offset: &offset) }
    // Enforce that all streams must have unique names.
    guard Set(streamHeaders.map { $0.Name }).count == streamHeaders.count else {
      throw WinMDError.BadImageFormat
    }
    
    self.Length = versionLength
    self.Version = version
    self.Streams = streamCount
    self.StreamHeaders = streamHeaders
    self.data = data
  }

  public var Signature: UInt32 { self.data[offset: self.data.index(self.data.startIndex, offsetBy: 0)] }
  public var MajorVersion: UInt16 { self.data[offset: self.data.index(self.data.startIndex, offsetBy: 4)] }
  public var MinorVersion: UInt16 { self.data[offset: self.data.index(self.data.startIndex, offsetBy: 6)] }
  public var Reserved: UInt32 { self.data[offset: self.data.index(self.data.startIndex, offsetBy: 8)] }
  public let Length: UInt32
  public let Version: String
  public var Streams: UInt16
  public let StreamHeaders: [StreamHeader]
}

extension MetadataRoot {
  public func stream(named name: Metadata.Stream) -> ArraySlice<UInt8>? {
    return stream(named: name.rawValue)
  }

  public func stream(named name: String) -> ArraySlice<UInt8>? {
    return self.StreamHeaders.first(where: { $0.Name == name }).map {
      let enterIndex = self.data.index(self.data.startIndex, offsetBy: numericCast($0.Offset))
      let exitIndex = self.data.index(enterIndex, offsetBy: numericCast($0.Size))
      
      return self.data[enterIndex..<exitIndex]
    }
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
