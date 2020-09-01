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

internal struct COR20File {
  internal let envelope: PEFile
  internal let data: Data

  public var Header: IMAGE_COR20_HEADER {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_COR20_HEADER.self).baseAddress!.pointee
    }
  }

  public var Metadata: Result<Data, WinMDError> {
    let metadata: IMAGE_DATA_DIRECTORY = Header.MetaData
    var section: IMAGE_SECTION_HEADER!

    switch envelope.Sections {
    case .failure(let error):
      return .failure(error)
    case .success(let sections):
      let headers: [IMAGE_SECTION_HEADER] =
          sections.containing(rva: metadata.VirtualAddress)
      guard headers.count == 1 else { return .failure(WinMDError.tooManySections) }
      section = headers.first
    }

    return .success(envelope.data.suffix(from: numericCast(section.offset(from: metadata.VirtualAddress))))
  }

  public init(from envelope: PEFile) throws {
    self.envelope = envelope

    var COMDescriptor: IMAGE_DATA_DIRECTORY!

    switch envelope.Header32.OptionalHeader.Magic {
    case WORD(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE: IMAGE_NT_HEADERS32 = envelope.Header32
      COMDescriptor = PE.OptionalHeader.DataDirectory.14
    case WORD(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE: IMAGE_NT_HEADERS64 = envelope.Header64
      COMDescriptor = PE.OptionalHeader.DataDirectory.14
    default:
      throw WinMDError.invalidNTSignature
    }

    var section: IMAGE_SECTION_HEADER!
    switch envelope.Sections {
    case .failure(let error):
      throw error
    case .success(let sections):
      let headers: [IMAGE_SECTION_HEADER] =
          sections.containing(rva: COMDescriptor.VirtualAddress)
      guard headers.count == 1 else { throw WinMDError.COMDescriptorNotFound }
      section = headers.first
    }

    self.data =
        envelope.data.suffix(from: numericCast(section.offset(from: COMDescriptor.VirtualAddress)))
  }

  public func validate() throws {
    guard data.count > MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw WinMDError.fileTooSmall
    }

    guard Header.cb == MemoryLayout<IMAGE_COR20_HEADER>.size else {
      throw WinMDError.invalidCLRSignature
    }
  }
}

internal var COR20_METADATA_SIGNATURE: DWORD { 0x424a5342 }

/// COR20 Metadata Root
///     uint32_t Signature          ; +0
///     uint16_t MajorVersion       ; +4
///     uint16_t MinorVersion       ; +6
///     uint32_t Reserved           ; +8
///     uint32_t Length             ; +12
///      uint8_t Version[]          ; +16
///     uint16_t Flags              ; +16 + Length
///     uint16_t Streams            ; +18 + Length
///     COR20 Stream Headers        ; +20 + Length
internal struct COR20Metadata {
  private let data: Data

  public init(parsing data: Data) {
    self.data = data
  }

  private func read<T: FixedWidthInteger>(offset: Data.Index) -> T {
    var value: T = 0
    withUnsafeMutableBytes(of: &value) {
      let begin: Data.Index = data.index(data.startIndex, offsetBy: offset)
      let end: Data.Index = data.index(begin, offsetBy: $0.count)
      data.copyBytes(to: $0, from: begin ..< end)
    }
    return value
  }

  public var Signature: UInt32 {
    return read(offset: 0)
  }

  public var MajorVersion: UInt16 {
    return read(offset: 4)
  }

  public var MinorVersion: UInt16 {
    return read(offset: 6)
  }

  public var Reserved: UInt32 {
    return read(offset: 8)
  }

  public var Length: UInt32 {
    return read(offset: 12)
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
    return read(offset: 18 + Int(Length))
  }
}

/// COR20 Stream Header
///     uint32_t Offset     ; +0
///     uint32_t Size       ; +4
///      uint8_t Name[]     ; +8
internal struct COR20StreamHeader {
  private let data: Data

  public init(parsing data: Data) {
    self.data = data
  }

  private func read<T: FixedWidthInteger>(offset: Data.Index) -> T {
    var value: T = 0
    withUnsafeMutableBytes(of: &value) {
      let begin: Data.Index = data.index(data.startIndex, offsetBy: offset)
      let end: Data.Index = data.index(begin, offsetBy: $0.count)
      data.copyBytes(to: $0, from: begin..<end)
    }
    return value
  }

  public var Offset: UInt32 {
    return read(offset: 0)
  }

  public var Size: UInt32 {
    return read(offset: 4)
  }

  public var Name: String {
    return String(decoding: data.suffix(from: 8), as: Unicode.ASCII.self)
  }
}
