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

internal struct PEFile {
  internal let data: Data

  public var Header32: IMAGE_NT_HEADERS32 {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS32.self).baseAddress!.pointee
    }
  }

  public var Header64: IMAGE_NT_HEADERS64 {
    return data.withUnsafeBytes {
      $0.bindMemory(to: IMAGE_NT_HEADERS64.self).baseAddress!.pointee
    }
  }

  public var Sections: Result<[IMAGE_SECTION_HEADER], WinMDError> {
    switch Header32.OptionalHeader.Magic {
    case WORD(IMAGE_NT_OPTIONAL_HDR32_MAGIC):
      let PE: IMAGE_NT_HEADERS32 = Header32
      let NumberOfSections: Int = Int(PE.FileHeader.NumberOfSections)
      let Offset: Int = MemoryLayout.size(ofValue: PE)

      return .success(Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes: Int = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin: Data.Index = data.index(data.startIndex, offsetBy: Offset)
        let end: Data.Index = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      })
    case WORD(IMAGE_NT_OPTIONAL_HDR64_MAGIC):
      let PE: IMAGE_NT_HEADERS64 = Header64
      let NumberOfSections: Int = Int(PE.FileHeader.NumberOfSections)
      let Offset: Int = MemoryLayout.size(ofValue: PE)

      return .success(Array<IMAGE_SECTION_HEADER>(unsafeUninitializedCapacity: NumberOfSections) {
        let nbytes: Int = NumberOfSections * MemoryLayout<IMAGE_SECTION_HEADER>.size
        let begin: Data.Index = data.index(data.startIndex, offsetBy: Offset)
        let end: Data.Index = data.index(begin, offsetBy: nbytes)
        data.copyBytes(to: $0, from: begin ..< end)
        $1 = NumberOfSections
      })
    default:
      return .failure(WinMDError.invalidNTSignature)
    }
  }

  public init(from envelope: DOSFile) {
    self.data =
        envelope.data.suffix(from: numericCast(envelope.Header.e_lfanew))
  }

  public func validate() throws {
    guard data.count > MemoryLayout<IMAGE_NT_HEADERS32>.size else {
      throw WinMDError.fileTooSmall
    }

    guard 0...100 ~= Header32.FileHeader.NumberOfSections else {
      throw WinMDError.tooManySections
    }
  }
}

extension Array where Array.Element == IMAGE_SECTION_HEADER {
  internal func containing(rva: DWORD) -> [IMAGE_SECTION_HEADER] {
    return self.filter {
      rva >= $0.VirtualAddress && rva < $0.VirtualAddress + $0.Misc.VirtualSize
    }
  }
}

extension IMAGE_SECTION_HEADER {
  internal func offset(from rva: DWORD) -> DWORD {
    return rva - self.VirtualAddress + self.PointerToRawData
  }
}
